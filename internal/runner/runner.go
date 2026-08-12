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

// terminateGroup sends TERM to the whole group, then KILL if it is still alive after the grace
// period, and returns the engine's final wait status. The NEGATIVE pid is what makes it a group
// signal rather than a signal to bash alone.
func terminateGroup(cmd *exec.Cmd, grace time.Duration, exited <-chan error) error {
	if grace <= 0 {
		grace = DefaultKillGrace
	}
	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err != nil {
		// Already reaped, or it never got its own group; fall back to signalling the child.
		pgid = cmd.Process.Pid
	}
	_ = syscall.Kill(-pgid, syscall.SIGTERM)

	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case werr := <-exited:
		return werr
	case <-timer.C:
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		return <-exited
	}
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
	// Config wins over anything inherited with the same name.
	for _, kv := range assignments {
		drop[nameOf(kv)] = true
	}

	out := make([]string, 0, len(os.Environ())+len(assignments))
	for _, kv := range os.Environ() {
		if !drop[nameOf(kv)] {
			out = append(out, kv)
		}
	}
	return append(out, assignments...), nil
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
