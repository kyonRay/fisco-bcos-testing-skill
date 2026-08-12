package runner

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
)

// The leader exiting on TERM is not the end of the story: a group member that IGNORES TERM keeps
// running, and returning as soon as bash is reaped leaves it behind. That member is the realistic
// case -- a JVM with its own shutdown handling, or a node process mid-write.
func TestAGroupMemberThatIgnoresTermIsStillKilled(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "stubborn.pid")
	stubborn := filepath.Join(dir, "stubborn.sh")
	if err := os.WriteFile(stubborn, []byte("#!/usr/bin/env bash\ntrap '' TERM\nsleep 60\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_, err := run(t, Spec{
		// The leader exits promptly on TERM; the child it started does not.
		Script:    script(t, stubborn+" &\necho $! > "+pidFile+"\nwait\n"),
		Timeout:   startupSlack,
		KillGrace: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > startupSlack+DrainGrace+8*time.Second {
		t.Fatalf("Run took %v", elapsed)
	}
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatalf("the stubborn child never recorded its pid: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	t.Errorf("process %d ignored TERM and survived: the host returned as soon as the leader died, "+
		"so the grace period never ended in KILL(-pgid)", pid)
}

// Non-interactive bash SOURCES $BASH_ENV before running the script. A file left there runs ahead of
// every engine script and can `exit 0` outright -- the script body never runs and the run still
// reports success. Verified by hand: the body's own echo never appears and the exit code is 0.
func TestBashEnvCannotHijackTheEngine(t *testing.T) {
	hook := filepath.Join(t.TempDir(), "hook.sh")
	if err := os.WriteFile(hook, []byte("echo HIJACKED\nexit 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BASH_ENV", hook)

	res, err := run(t, Spec{Script: script(t, "echo BODY-RAN\n")})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(res.Stdout), "HIJACKED") {
		t.Errorf("BASH_ENV ran ahead of the engine script: %q", res.Stdout)
	}
	if !strings.Contains(string(res.Stdout), "BODY-RAN") {
		t.Errorf("the engine script body never ran, yet exit=%d -- a false green: %q",
			res.ExitCode, res.Stdout)
	}
}

// The rest of bash's interpreter controls can change what a script means before its first line:
// SHELLOPTS/BASHOPTS force shell options on, CDPATH silently redirects cd, ENV is BASH_ENV's
// POSIX-mode sibling, and an exported BASH_FUNC_x%% replaces a function the script calls.
func TestInterpreterControlVariablesAreStripped(t *testing.T) {
	t.Setenv("CDPATH", "/tmp")
	t.Setenv("ENV", "/nonexistent")
	t.Setenv("BASH_FUNC_myfunc%%", "() { echo hijacked; }")
	res, err := run(t, Spec{Script: script(t,
		`echo "cdpath=[${CDPATH:-}] env=[${ENV:-}] fn=[$(type -t myfunc 2>/dev/null)]"`)})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"cdpath=[]", "env=[]", "fn=[]"} {
		if !strings.Contains(string(res.Stdout), want) {
			t.Errorf("want %s in %q", want, res.Stdout)
		}
	}
}

// The two strip sources must stay disjoint and neither may ever become bindable. A config key that
// mapped onto BASH_ENV would let fbt.yaml re-open the door this file exists to close.
func TestInterpreterControlsAreNeitherConfigurableNorDuplicated(t *testing.T) {
	onStripList := map[string]bool{}
	for _, n := range keys.MustStrip() {
		onStripList[n] = true
	}
	for _, n := range interpreterControls {
		if onStripList[n] {
			t.Errorf("%q is on both lists; one of them is the wrong home for it", n)
		}
		for _, r := range keys.Rows() {
			for _, env := range r.Env {
				if env == n {
					t.Errorf("config key %q binds to %q, an interpreter control that must never "+
						"be settable", r.Key, n)
				}
			}
		}
	}
	if len(interpreterControls) < 5 {
		t.Fatalf("only %d interpreter controls listed -- suspiciously short", len(interpreterControls))
	}
}
