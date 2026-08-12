package runner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
)

// script writes a real bash script and returns its path. Tests drive real processes, real signals
// and real pipes; they just never build a chain.
func script(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "engine.sh")
	if err := os.WriteFile(p, []byte("#!/usr/bin/env bash\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

// startupSlack is how long every deadline in this file waits before firing.
//
// It is not arbitrary: on this machine a script whose entire body is `echo A` takes 350-510ms to
// run end to end, because macOS scans a freshly written executable before exec'ing it. A 200ms
// deadline therefore fires BEFORE the script's first line runs, and the test then "proves" the
// kill worked while actually having killed a process that never started. Every timing assertion
// here needs headroom well above that floor.
const startupSlack = 2 * time.Second

func run(t *testing.T, s Spec) (Result, error) {
	t.Helper()
	if s.Dir == "" {
		s.Dir = t.TempDir()
	}
	return Run(context.Background(), s)
}

func TestExitCodeAndStreamsAreCaptured(t *testing.T) {
	res, err := run(t, Spec{Script: script(t, "echo out; echo err >&2; exit 7")})
	if err != nil {
		t.Fatal(err)
	}
	if res.ExitCode != 7 {
		t.Errorf("ExitCode = %d, want 7", res.ExitCode)
	}
	if strings.TrimSpace(string(res.Stdout)) != "out" || strings.TrimSpace(string(res.Stderr)) != "err" {
		t.Errorf("stdout=%q stderr=%q; the two streams must stay separate", res.Stdout, res.Stderr)
	}
	if res.TimedOut || res.Signaled {
		t.Errorf("a clean exit must not look timed out or signalled: %+v", res)
	}
}

// THE debt 1A handed over. A leftover SCENARIO_DRY=1 in the operator's shell would otherwise turn
// every gate run into a no-op that still exits 0.
func TestStrippedVariablesNeverReachTheEngine(t *testing.T) {
	body := ""
	for _, name := range keys.MustStrip() {
		body += fmt.Sprintf("echo \"%s=[${%s:-}]\"\n", name, name)
	}
	for _, name := range keys.MustStrip() {
		t.Setenv(name, "1") // present in the host environment, exactly as a stale shell would have it
	}
	res, err := run(t, Spec{Script: script(t, body)})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range keys.MustStrip() {
		if !strings.Contains(string(res.Stdout), name+"=[]") {
			t.Errorf("%s survived into the engine environment:\n%s", name, res.Stdout)
		}
	}
	if len(keys.MustStrip()) < 5 {
		t.Fatalf("only %d names on the strip list -- this test would be nearly vacuous", len(keys.MustStrip()))
	}
}

// The host's own environment still passes through: the engine needs PATH to find bash's helpers.
func TestUnrelatedEnvironmentIsInherited(t *testing.T) {
	t.Setenv("FBT_TEST_MARKER", "kept")
	res, err := run(t, Spec{Script: script(t, `echo "marker=[${FBT_TEST_MARKER:-}] path=[${PATH:+set}]"`)})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res.Stdout), "marker=[kept]") ||
		!strings.Contains(string(res.Stdout), "path=[set]") {
		t.Errorf("got %q", res.Stdout)
	}
}

// Config reaches the engine under its legacy names, and overrides whatever the shell had.
func TestConfigIsTranslatedAndOverridesInheritedValues(t *testing.T) {
	t.Setenv("RG_FUZZ_BATCH", "9") // stale value in the shell
	res, err := run(t, Spec{
		Script: script(t, `echo "batch=[${RG_FUZZ_BATCH:-}] group=[${BCOS_GROUP_ID:-}]"`),
		Config: map[string]string{"fuzz.batch": "250", "cluster.group_id": "group7"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res.Stdout), "batch=[250]") ||
		!strings.Contains(string(res.Stdout), "group=[group7]") {
		t.Errorf("got %q", res.Stdout)
	}
}

// One key, two names: injecting only one would aim dual_rpc and the fuzz driver at different nodes.
func TestAKeyWithTwoEnvNamesInjectsBoth(t *testing.T) {
	res, err := run(t, Spec{
		Script: script(t, `echo "a=[${WEB3_RPC_URL:-}] b=[${RG_FUZZ_WEB3_URL:-}]"`),
		Config: map[string]string{"cluster.web3_rpc_url": "http://h:9"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res.Stdout), "a=[http://h:9] b=[http://h:9]") {
		t.Errorf("got %q", res.Stdout)
	}
}

func TestInvalidConfigIsRejectedBeforeAnyProcessStarts(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran")
	_, err := run(t, Spec{
		Script: script(t, "touch "+marker),
		Config: map[string]string{"fuzz.batch": "abc"},
	})
	if err == nil {
		t.Fatal("want an error")
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
		t.Errorf("want ClassConfig, got %v", c)
	}
	if _, statErr := os.Stat(marker); statErr == nil {
		t.Error("the engine ran despite an invalid configuration")
	}
}

// spec §8: fd 3 is the engine-to-host event pipe, separate from stdout.
func TestFD3IsDeliveredToTheEventSink(t *testing.T) {
	var lines []string
	res, err := run(t, Spec{
		Script: script(t, `echo '{"ev":"a"}' >&3; echo on-stdout; echo '{"ev":"b"}' >&3`),
		Events: func(line []byte) { lines = append(lines, string(line)) },
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 || !strings.Contains(lines[0], `"a"`) || !strings.Contains(lines[1], `"b"`) {
		t.Errorf("event lines = %q", lines)
	}
	if strings.Contains(string(res.Stdout), `"ev"`) {
		t.Errorf("events leaked into stdout: %q", res.Stdout)
	}
	if !strings.Contains(string(res.Stdout), "on-stdout") {
		t.Errorf("stdout lost its own output: %q", res.Stdout)
	}
}

// The engine must run standalone too: writing to fd 3 when nobody reads it cannot kill it.
func TestEngineWithoutAnEventSinkStillRuns(t *testing.T) {
	res, err := run(t, Spec{Script: script(t, `echo '{"ev":"x"}' >&3 2>/dev/null; echo alive`)})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res.Stdout), "alive") {
		t.Errorf("got %q", res.Stdout)
	}
}

func TestArgsAndWorkingDirectoryAreHonoured(t *testing.T) {
	dir := t.TempDir()
	res, err := run(t, Spec{
		Script: script(t, `echo "args=[$*] cwd=[$PWD]"`),
		Args:   []string{"-p", "prod", "--dry-run"},
		Dir:    dir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res.Stdout), "args=[-p prod --dry-run]") {
		t.Errorf("args lost: %q", res.Stdout)
	}
	// macOS hands out /var/folders/... whose real path is /private/var/folders/...
	real, _ := filepath.EvalSymlinks(dir)
	if !strings.Contains(string(res.Stdout), "cwd=["+dir+"]") &&
		!strings.Contains(string(res.Stdout), "cwd=["+real+"]") {
		t.Errorf("cwd = %q, want %q", res.Stdout, dir)
	}
}

// spec §9/§11: a deadline makes the run infra (30). The signal the host itself sent must NOT then
// be re-read as "the engine died unexpectedly" (40).
func TestTimeoutIsReportedAsTimeoutNotAsASignalDeath(t *testing.T) {
	start := time.Now()
	res, err := run(t, Spec{Script: script(t, "sleep 30"), Timeout: startupSlack})
	if err != nil {
		t.Fatal(err)
	}
	if !res.TimedOut {
		t.Error("TimedOut is false after the deadline passed")
	}
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Errorf("the deadline took %v to take effect", elapsed)
	}
}

// spec §10: kill the whole process group, or Java, curl and node processes survive as orphans.
//
// The teardown is triggered by CANCELLATION rather than a deadline, and that is deliberate: both
// paths call the same terminateGroup, but a deadline is a wall-clock race against process startup.
// An earlier version fired at 2s and went red under a loaded machine because the script had not yet
// reached the line that records its child's pid -- the test was then asserting against a process
// that never existed. Waiting for the child to actually be there and only then pulling the trigger
// removes the race instead of enlarging the constant. The deadline's own job -- bounding the run --
// is covered by TestTimeoutIsReportedAsTimeoutNotAsASignalDeath.
func TestTeardownKillsTheWholeProcessGroupNotJustBash(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "child.pid")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	type outcome struct {
		res     Result
		err     error
		elapsed time.Duration
	}
	done := make(chan outcome, 1)
	start := time.Now()
	go func() {
		res, err := Run(ctx, Spec{
			Script: script(t, `
sleep 30 &
echo $! > `+pidFile+`.tmp
mv `+pidFile+`.tmp `+pidFile+`
wait
`),
			Dir:     dir,
			Timeout: 60 * time.Second,
		})
		done <- outcome{res, err, time.Since(start)}
	}()

	pid := waitForPID(t, pidFile)
	cancelledAt := time.Now()
	cancel()

	got := <-done
	if got.err != nil {
		t.Fatal(got.err)
	}
	// Returning promptly is half the contract, and the half that catches the subtler bug: when
	// only bash is signalled, the orphaned `sleep` keeps the stdout write end open, Run blocks
	// until it exits on its own 30s later, and by then the liveness check below passes for the
	// wrong reason. Without this assertion the test goes green against a runner whose teardown
	// does not actually bound anything.
	if since := time.Since(cancelledAt); since > DrainGrace+8*time.Second {
		t.Errorf("Run took %v after the cancellation; the teardown did not bound the run", since)
	}
	assertReaped(t, pid, "grandchild %d survived the group kill -- only bash was signalled")
}

// waitForPID blocks until the script has recorded its child's pid. The file is written under a
// temporary name and renamed, so a partially written file can never be read as a pid.
func waitForPID(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil {
			pid, convErr := strconv.Atoi(strings.TrimSpace(string(raw)))
			if convErr == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("the child never recorded its pid at %s within 30s", path)
	return 0
}

// assertReaped waits for a process to disappear, then reports it with the caller's message if it
// is still there. It KILLs a survivor so a failing test does not leak a process either.
func assertReaped(t *testing.T, pid int, format string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	t.Errorf(format, pid)
}

// A process that ignores TERM must still die: the grace period ends in KILL.
func TestATermIgnoringEngineIsKilledAfterTheGracePeriod(t *testing.T) {
	res, err := run(t, Spec{
		Script:    script(t, "trap '' TERM; sleep 30"),
		Timeout:   startupSlack,
		KillGrace: 500 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.TimedOut {
		t.Errorf("got %+v", res)
	}
}

// Cancelling the context is the SIGINT path: 130 territory, not a timeout.
func TestContextCancellationStopsTheEngineWithoutClaimingATimeout(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(startupSlack); cancel() }()
	res, err := Run(ctx, Spec{Script: script(t, "sleep 30"), Dir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if res.TimedOut {
		t.Error("a cancellation is not a timeout")
	}
	if !res.Canceled {
		t.Errorf("got %+v, want Canceled", res)
	}
}

// An engine killed by something other than the host (a real crash) is distinguishable, because
// that is what makes it exit 40 rather than 30.
func TestAnUnprovokedSignalDeathIsReportedAsSignaled(t *testing.T) {
	res, err := run(t, Spec{Script: script(t, "kill -ABRT $$")})
	if err != nil {
		t.Fatal(err)
	}
	if !res.Signaled || res.TimedOut || res.Canceled {
		t.Errorf("got %+v, want Signaled only", res)
	}
	if res.Signal != syscall.SIGABRT {
		t.Errorf("Signal = %v, want SIGABRT", res.Signal)
	}
}

func TestAMissingScriptIsAnInfraError(t *testing.T) {
	_, err := run(t, Spec{Script: filepath.Join(t.TempDir(), "absent.sh")})
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassInfra {
		t.Errorf("want ClassInfra, got %v (err=%v)", c, err)
	}
}

func TestAMissingWorkingDirectoryIsAnInfraError(t *testing.T) {
	_, err := Run(context.Background(), Spec{
		Script: script(t, "true"), Dir: filepath.Join(t.TempDir(), "gone"),
	})
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassInfra {
		t.Errorf("want ClassInfra, got %v (err=%v)", c, err)
	}
}

// Large outputs must not deadlock: a child filling the stdout pipe while the host waits on exit is
// the classic hang, and a gate run produces plenty of output.
func TestLargeOutputDoesNotDeadlock(t *testing.T) {
	// Counted on the live writer, not on Result: Result deliberately keeps only a tail, and
	// counting there would turn this deadlock test into an assertion about the tail size.
	var full strings.Builder
	_, err := run(t, Spec{
		Script: script(t, `for i in $(seq 1 20000); do echo "line $i padding padding padding"; done`),
		Stdout: &full,
	})
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(full.String(), "\n"); n != 20000 {
		t.Errorf("captured %d lines, want 20000", n)
	}
}
