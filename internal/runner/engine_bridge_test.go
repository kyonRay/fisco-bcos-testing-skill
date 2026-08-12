package runner_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/events"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/runner"
)

// This is the only test that drives the REAL bash engine through the REAL Go host. Everything
// either side proves in isolation -- the engine emits well-formed events, the normalizer accepts
// well-formed events -- is worthless if the two never meet: fd 3 has to be the same fd on both
// sides, the schema major has to match the manifest, and the terminator has to arrive.
//
// It stays off a live chain by using --dry-run and deliberate usage errors.
func runEngine(t *testing.T, args ...string) ([]events.Event, runner.Result) {
	t.Helper()
	repo, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	n := &events.Normalizer{RunID: "bridge-run", ExpectedEventMajor: 1}

	var got []events.Event
	var readErr error
	res, err := runner.Run(context.Background(), runner.Spec{
		Script:  filepath.Join(repo, "scripts", args[0]),
		Args:    args[1:],
		Dir:     repo,
		Timeout: 60 * time.Second,
		Events: func(line []byte) {
			if e := n.Read("engine", strings.NewReader(string(line)+"\n"), func(ev events.Event) {
				got = append(got, ev)
			}); e != nil && readErr == nil {
				readErr = e
			}
		},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if readErr != nil {
		t.Fatalf("the engine emitted an event the host rejects: %v", readErr)
	}
	return got, res
}

func names(evs []events.Event) []string {
	out := make([]string, 0, len(evs))
	for _, e := range evs {
		out = append(out, e.Ev)
	}
	return out
}

func TestRealEngineEventsSurviveTheRoundTrip(t *testing.T) {
	profile := "profiles/production-enterprise.profile"
	for _, argv := range [][]string{
		{"gate.sh", "-p", profile, "--dry-run"},
		{"apply_profile.sh", "-p", profile, "--dry-run"},
		{"run_case.sh", "scenarios/example.case", "--dry-run"},
		{"gate_upgrade.sh", "-p", profile, "--old-bin", profile, "--new-bin", profile,
			"--target-ver", "3.17.0", "--dry-run"},
	} {
		evs, res := runEngine(t, argv...)
		if res.ExitCode != 0 {
			t.Errorf("%s: exit %d\n%s", argv[0], res.ExitCode, res.Stderr)
		}
		got := names(evs)
		if len(got) < 2 || got[0] != "command_started" || got[len(got)-1] != "command_finished" {
			t.Errorf("%s: events = %v, want command_started first and command_finished last",
				argv[0], got)
			continue
		}
		var finishes int
		for _, e := range evs {
			if e.Ev == "command_finished" {
				finishes++
				if e.Payload["outcome"] != "pass" {
					t.Errorf("%s: outcome = %v, want pass", argv[0], e.Payload["outcome"])
				}
				// engine_exit must arrive as a NUMBER. Quoted, every consumer comparing it to 0
				// would have to know to unquote it first, and one that forgot would read every
				// exit as truthy.
				if n, ok := e.Payload["engine_exit"]; !ok {
					t.Errorf("%s: command_finished carries no engine_exit", argv[0])
				} else if s := n.(interface{ String() string }).String(); s != "0" {
					t.Errorf("%s: engine_exit = %s, want 0", argv[0], s)
				}
			}
		}
		if finishes != 1 {
			t.Errorf("%s: %d command_finished events, want exactly 1", argv[0], finishes)
		}
		// The host owns the envelope; the engine must not be inventing it.
		if evs[0].RunID != "bridge-run" || evs[0].Seq != 1 {
			t.Errorf("%s: envelope = %+v", argv[0], evs[0])
		}
	}
}

// The case the whole "arm the trap before parsing" rule exists for: without a terminator the host
// reports its own bug (40) for what is really the user forgetting a flag (20).
func TestAUsageErrorStillTerminatesProperly(t *testing.T) {
	evs, res := runEngine(t, "gate.sh")
	if res.ExitCode != 2 {
		t.Fatalf("exit = %d, want 2", res.ExitCode)
	}
	if len(evs) == 0 || evs[len(evs)-1].Ev != "command_finished" {
		t.Fatalf("events = %v, want a command_finished", names(evs))
	}
	last := evs[len(evs)-1]
	if last.Payload["outcome"] != "config_error" {
		t.Errorf("outcome = %v, want config_error", last.Payload["outcome"])
	}
	if !strings.Contains(string(res.Stderr), "-p <profile> is required") {
		t.Errorf("the human diagnostic is missing from stderr: %q", res.Stderr)
	}
}

// The engine's own stdout must not carry event text: the two channels are separate on purpose, and
// a host reading only stdout in --output json mode would otherwise find JSON lines mixed into it.
func TestEventsDoNotLeakIntoStdout(t *testing.T) {
	_, res := runEngine(t, "gate.sh", "-p", "profiles/production-enterprise.profile", "--dry-run")
	if strings.Contains(string(res.Stdout), "schema_version") {
		t.Errorf("event text leaked into stdout: %q", res.Stdout)
	}
	if !strings.Contains(string(res.Stdout), "gate dry-run") {
		t.Errorf("the engine's own stdout is missing: %q", res.Stdout)
	}
}

// The host tells the engine where to build. A fixed directory name would make two concurrent runs
// share one cluster, and the engine cannot isolate itself by chdir'ing because its cwd must stay
// the repo root.
func TestTheHostChoosesTheWorkspace(t *testing.T) {
	ws := t.TempDir()
	for _, argv := range [][]string{
		{"gate.sh", "-p", "profiles/production-enterprise.profile", "-o", ws, "--dry-run"},
		{"run_case.sh", "scenarios/example.case", "-o", ws, "--dry-run"},
	} {
		_, res := runEngine(t, argv...)
		if !strings.Contains(string(res.Stdout), ws) {
			t.Errorf("%s: the plan does not mention the host's workspace %q:\n%s",
				argv[0], ws, res.Stdout)
		}
	}
}

// The strip list has to hold across the bridge too, not just in buildEnv's unit test: this is the
// combination that actually ships.
func TestScenarioDryCannotReachTheRealEngine(t *testing.T) {
	t.Setenv("SCENARIO_DRY", "1")
	_, res := runEngine(t, "gate.sh", "-p", "profiles/production-enterprise.profile", "--dry-run")
	if !strings.Contains(string(res.Stdout), "gate dry-run") {
		t.Errorf("the engine did not run its normal path: %q", res.Stdout)
	}
}

// Every directly-launched entry point must be executable in the repository itself. The bash tests
// all invoke these as `bash scripts/x.sh`, so a 0644 file passes every one of them while the host,
// which execs the file, gets "permission denied" -- which is exactly what happened before this
// test existed. Libraries stay non-executable on purpose: an executable library invites someone to
// run it.
func TestEveryEntryPointIsExecutableAndLibrariesAreNot(t *testing.T) {
	repo, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	entryPoints := []string{"gate.sh", "run_case.sh", "apply_profile.sh", "fuzz_bcos.sh",
		"gate_upgrade.sh", "oracle_crash.sh", "oracle_liveness.sh", "oracle_stateroot.sh"}
	libraries := []string{"event_lib.sh", "profile_lib.sh", "oracle_lib.sh", "failures_lib.sh"}

	for _, name := range entryPoints {
		st, err := os.Stat(filepath.Join(repo, "scripts", name))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if st.Mode().Perm()&0o111 == 0 {
			t.Errorf("%s is mode %04o: the host execs it directly and would get permission denied",
				name, st.Mode().Perm())
		}
	}
	for _, name := range libraries {
		st, err := os.Stat(filepath.Join(repo, "scripts", name))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if st.Mode().Perm()&0o111 != 0 {
			t.Errorf("%s is executable (mode %04o) but is only ever sourced", name, st.Mode().Perm())
		}
	}
}

// A non-executable script must produce a sentence naming the mode, not a bare permission-denied.
func TestANonExecutableScriptIsAClearInfraError(t *testing.T) {
	p := filepath.Join(t.TempDir(), "noexec.sh")
	if err := os.WriteFile(p, []byte("#!/usr/bin/env bash\ntrue\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := runner.Run(context.Background(), runner.Spec{Script: p, Dir: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "not executable") {
		t.Errorf("got %v, want an error naming the missing exec bit", err)
	}
}
