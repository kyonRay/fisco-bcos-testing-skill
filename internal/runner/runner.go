// Package runner starts one engine script as a subprocess and brings it back down cleanly.
//
// It owns four things the rest of the host depends on and cannot do piecemeal: the environment the
// engine sees (spec §7.5), the process group (§10), the fd 3 event pipe (§8), and the distinction
// between a deadline, a cancellation and an unprovoked crash (§9, §11).
package runner

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
)

// DefaultKillGrace is how long a TERMed process group has before it is KILLed.
const DefaultKillGrace = 5 * time.Second

// DrainGrace bounds how long Run waits for the output pipes to reach EOF after the engine has
// exited. Past it the read ends are closed, so a surviving orphan holding a write end costs a
// truncated tail rather than a run that never returns.
const DrainGrace = 2 * time.Second

type Spec struct {
	Script string // absolute path to the engine script
	Args   []string
	Dir    string            // the engine's working directory; the host passes repo.root (spec §7.3)
	Config map[string]string // canonical config keys; translated to legacy env names here

	// Events receives one raw fd 3 line at a time. Nil means nobody is listening -- the engine
	// must still run, because it has to work standalone (spec §4).
	Events func(line []byte)

	Timeout   time.Duration // 0 means no deadline
	KillGrace time.Duration // 0 means DefaultKillGrace
}

type Result struct {
	ExitCode int
	Signaled bool
	Signal   syscall.Signal
	// TimedOut and Canceled record that the HOST brought the process down. Without them the
	// signal death below would be re-read as "the engine died unexpectedly" (exit 40) when in
	// fact the host sent that signal on purpose (spec §9's timeout special case).
	TimedOut bool
	Canceled bool
	Stdout   []byte
	Stderr   []byte
}

// Run starts the engine, streams its three outputs, and waits for it to finish.
//
// It returns an error only when the run could not be attempted or the host itself failed; an
// engine that exits non-zero, is signalled, or hits the deadline comes back as a Result, because
// those are outcomes the caller has to classify, not failures of Run.
func Run(ctx context.Context, s Spec) (Result, error) {
	env, err := buildEnv(s.Config)
	if err != nil {
		// Before any process starts (spec §11): a bad value must not reach bash.
		return Result{}, err
	}
	if st, statErr := os.Stat(s.Script); statErr != nil || st.IsDir() {
		return Result{}, fbterr.Infraf("engine script %s is missing or not a file", s.Script)
	}
	if st, statErr := os.Stat(s.Dir); statErr != nil || !st.IsDir() {
		return Result{}, fbterr.Infraf("working directory %s does not exist "+
			"(the engine runs with the FISCO checkout root as its cwd)", s.Dir)
	}

	cmd := exec.Command(s.Script, s.Args...)
	cmd.Dir = s.Dir
	cmd.Env = env
	// Setpgid puts the engine in its own process group, so the host can signal the whole subtree.
	// Signalling only the direct child leaves the java, curl and node processes it started running
	// (spec §10).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// The three pipes are OURS, not exec's.
	//
	// Handing exec a bytes.Buffer makes it spawn a copier that cmd.Wait() then waits on, and that
	// copier only finishes when EVERY holder of the write end is gone. A background process the
	// engine spawned inherits that write end, so an orphan that outlives the killed shell keeps
	// Wait() blocked -- and the deadline stops bounding the run at all. Observed: killing only
	// bash made a 400ms-deadline run return after 30s, when its orphaned `sleep 30` finally
	// exited. Owning the pipes means Wait() returns as soon as the process does, and the drain is
	// bounded separately below.
	outR, outW, err := os.Pipe()
	if err != nil {
		return Result{}, fbterr.Hostf("cannot create the stdout pipe: %v", err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		outR.Close()
		outW.Close()
		return Result{}, fbterr.Hostf("cannot create the stderr pipe: %v", err)
	}
	// fd 3: ExtraFiles[0] becomes the child's fd 3. Handing it a real pipe even when Events is nil
	// keeps the engine's `>&3` writes harmless either way.
	eventR, eventW, err := os.Pipe()
	if err != nil {
		outR.Close()
		outW.Close()
		errR.Close()
		errW.Close()
		return Result{}, fbterr.Hostf("cannot create the fd 3 event pipe: %v", err)
	}
	cmd.Stdout, cmd.Stderr = outW, errW
	cmd.ExtraFiles = []*os.File{eventW}

	if err := cmd.Start(); err != nil {
		for _, f := range []*os.File{outR, outW, errR, errW, eventR, eventW} {
			f.Close()
		}
		return Result{}, fbterr.Infraf("cannot start %s: %v", s.Script, err)
	}
	// The host's copies of the write ends must go, or the readers never see EOF.
	outW.Close()
	errW.Close()
	eventW.Close()

	var stdout, stderr bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(3)
	go func() { defer wg.Done(); io.Copy(&stdout, outR) }()
	go func() { defer wg.Done(); io.Copy(&stderr, errR) }()
	go func() { defer wg.Done(); drainEvents(eventR, s.Events) }()

	res := wait(ctx, cmd, s)

	// Bounded drain: normally every reader is already at EOF. If an orphan still holds a write end
	// open, closing the read ends unblocks them rather than letting Run hang indefinitely.
	drained := waitFor(&wg, DrainGrace)
	outR.Close()
	errR.Close()
	eventR.Close()
	if !drained {
		wg.Wait() // the closes above release the blocked readers
	}
	res.Stdout, res.Stderr = stdout.Bytes(), stderr.Bytes()
	return res, nil
}

// waitFor reports whether wg finished within d.
func waitFor(wg *sync.WaitGroup, d time.Duration) bool {
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

// wait blocks until the engine exits, the deadline passes, or the context is cancelled. In the
// latter two cases it takes the process group down and records WHY, so the caller can tell a
// host-initiated kill from a crash.
func wait(ctx context.Context, cmd *exec.Cmd, s Spec) Result {
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	var deadline <-chan time.Time
	if s.Timeout > 0 {
		timer := time.NewTimer(s.Timeout)
		defer timer.Stop()
		deadline = timer.C
	}

	var res Result
	select {
	case err := <-done:
		fillStatus(&res, err)
		return res
	case <-deadline:
		res.TimedOut = true
	case <-ctx.Done():
		res.Canceled = true
	}

	// The signal below comes from us. TimedOut/Canceled stay standing afterwards: letting the
	// signal death win would turn a chain that stopped responding (30) into a host bug report (40).
	fillStatus(&res, terminateGroup(cmd, s.KillGrace, done))
	return res
}

// groupPollInterval is how often the group is re-checked for survivors after the leader is gone.
const groupPollInterval = 50 * time.Millisecond

// terminateGroup sends TERM to the whole group and does not return until the group is empty or the
// grace period has ended in KILL. It returns the engine's wait status.
//
// The leader exiting is NOT the end of it. A member that ignores TERM -- a JVM with its own
// shutdown handling, a node process mid-write -- keeps running after bash is reaped, and returning
// at that moment leaves it behind holding ports and writing to the cluster directory. So the grace
// period is measured from the TERM, spans the leader's death, and ends in KILL for the whole group
// if anything is still there.
func terminateGroup(cmd *exec.Cmd, grace time.Duration, exited <-chan error) error {
	if grace <= 0 {
		grace = DefaultKillGrace
	}
	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err != nil {
		// Already reaped, or it never got its own group; fall back to the child's own pid, which
		// is the group id Setpgid would have given it.
		pgid = cmd.Process.Pid
	}
	if own, ownErr := syscall.Getpgid(os.Getpid()); ownErr == nil && own == pgid {
		// Setpgid must have failed. Signalling this group would take the host down with it, so
		// signal only the child and let the caller's own deadline handle the rest.
		_ = cmd.Process.Signal(syscall.SIGKILL)
		return <-exited
	}

	deadline := time.Now().Add(grace)
	_ = syscall.Kill(-pgid, syscall.SIGTERM)

	// Phase 1: the leader, bounded by the same grace period.
	var werr error
	timer := time.NewTimer(grace)
	select {
	case werr = <-exited:
		timer.Stop()
	case <-timer.C:
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		werr = <-exited
	}

	// Phase 2: the rest of the group. kill(-pgid, 0) fails once no member is left.
	for time.Now().Before(deadline) {
		if syscall.Kill(-pgid, 0) != nil {
			return werr
		}
		time.Sleep(groupPollInterval)
	}
	if syscall.Kill(-pgid, 0) == nil {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}
	return werr
}

func fillStatus(res *Result, err error) {
	if err == nil {
		return
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		res.ExitCode = -1
		return
	}
	st, ok := ee.Sys().(syscall.WaitStatus)
	if !ok {
		res.ExitCode = ee.ExitCode()
		return
	}
	if st.Signaled() {
		res.Signaled = true
		res.Signal = st.Signal()
		// Conventional shell encoding, so a caller that only looks at ExitCode still sees failure.
		res.ExitCode = 128 + int(st.Signal())
		return
	}
	res.ExitCode = st.ExitStatus()
}

// buildEnv produces the environment the engine sees: the host's own, MINUS every stripped name,
// PLUS the translated configuration.
//
// The subtraction is the point (spec §7.5). Those variables substitute which script runs, or
// whether it does any work at all -- a leftover SCENARIO_DRY=1 in an operator's shell turns a
// whole gate round into a no-op that still exits 0.
func buildEnv(config map[string]string) ([]string, error) {
	assignments, err := keys.Translate(config)
	if err != nil {
		return nil, err
	}

	drop := map[string]bool{}
	for _, name := range keys.MustStrip() {
		drop[name] = true
	}
	for _, name := range interpreterControls {
		drop[name] = true
	}
	// Config wins over anything inherited with the same name.
	for _, kv := range assignments {
		drop[nameOf(kv)] = true
	}

	out := make([]string, 0, len(os.Environ())+len(assignments))
	for _, kv := range os.Environ() {
		name := nameOf(kv)
		if drop[name] || isExportedFunction(name) {
			continue
		}
		out = append(out, kv)
	}
	return append(out, assignments...), nil
}

// interpreterControls change what bash executes BEFORE or INSTEAD OF the script it was handed.
// They are not configuration -- no config key may ever bind to them -- so they live here rather
// than in the key registry, which describes settings a user is allowed to express.
//
// The one that makes this non-optional is BASH_ENV: non-interactive bash sources the file it names
// before running the script. A hook left there can `exit 0`, and then the engine script's body
// never runs while the run still reports success -- the same false green SCENARIO_DRY=1 produces,
// through a door the strip list does not cover. Verified by hand: with BASH_ENV set to a file
// containing `exit 0`, the script's own output never appears and the exit code is 0.
var interpreterControls = []string{
	"BASH_ENV",  // sourced before a non-interactive script
	"ENV",       // the same thing in POSIX mode
	"SHELLOPTS", // forces set -o options on, changing what the script's own set lines mean
	"BASHOPTS",  // the same for shopt
	"CDPATH",    // silently redirects every relative cd
	"IFS",       // changes how every unquoted expansion is split
	"GLOBIGNORE",
}

// isExportedFunction matches bash's exported-function encoding (BASH_FUNC_name%%). An entry there
// replaces a function the engine script calls, which substitutes behaviour just as thoroughly as
// substituting the script itself.
func isExportedFunction(name string) bool {
	return strings.HasPrefix(name, "BASH_FUNC_")
}

func nameOf(assignment string) string {
	if i := strings.IndexByte(assignment, '='); i >= 0 {
		return assignment[:i]
	}
	return assignment
}

// drainEvents reads fd 3 to EOF. It must consume the pipe even with no sink: leaving it unread
// would eventually block an engine that emits many events.
func drainEvents(r io.Reader, sink func([]byte)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		if sink == nil {
			continue
		}
		line := append([]byte(nil), sc.Bytes()...) // the scanner reuses its buffer
		sink(line)
	}
}
