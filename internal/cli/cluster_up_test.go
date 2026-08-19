package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/testinstall"
)

// stubApplyProfile installs the one script `cluster up` drives.
func stubApplyProfile(t *testing.T, ti testinstall.Install, body string) {
	t.Helper()
	lib := `source "$(dirname "$0")/event_lib.sh"` + "\n"
	ti.WriteScript(t, "apply_profile.sh", lib+"event_begin_command apply_profile.sh\n"+body)
}

// The whole point of the command: the chain outlives the process that built it. `gate run` releases
// its reservation on the way out, so before this existed nothing could produce a cluster for
// `fuzz run --attach` to attach to.
func TestClusterUpLeavesTheClusterAndItsReservationInPlace(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	stubApplyProfile(t, ti, "echo up\nevent_set_outcome pass\n")

	code, out, e := runReal(t, append([]string{"--output", "json"},
		append(flags, "cluster", "up", "-p", "default-latest")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v (%s)", code, e)
	}
	var doc UpDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.RunID == "" || doc.Workspace == "" || len(doc.Ports) == 0 {
		t.Fatalf("doc = %+v; the run id is the handle every later command needs", doc)
	}
	if !kept(t, ti) {
		t.Error("the reservation was released; the ports would be handed to the next run while " +
			"this cluster is still listening on them")
	}
}

// A cluster that failed halfway may still have nodes listening. Releasing its ports would hand
// them to the next run, which would then collide with something fbt believes is gone.
func TestAFailedBringUpKeepsItsReservation(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	stubApplyProfile(t, ti, "event_set_outcome infra_error\nexit 1\n")

	code, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "cluster", "up", "-p", "default-latest")...)...)
	if code != exitcode.Infra {
		t.Fatalf("code = %v, want 30\n%s", code, out)
	}
	if !kept(t, ti) {
		t.Error("a half-built cluster released its ports")
	}
}

func kept(t *testing.T, ti testinstall.Install) bool {
	t.Helper()
	entries, _ := os.ReadDir(filepath.Join(ti.State, "clusters"))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			return true
		}
	}
	return false
}

// Reserved, not silently ignored and not an unknown-flag error. "flag provided but not defined"
// reads like a typo in the flag name; this has to read like "the feature is not built yet".
func TestWithFuzzIsRefusedAsConfigNotAsAnUnknownFlag(t *testing.T) {
	_, flags := gateFixture(t, cleanGate, cleanCase)

	code, _, e := runReal(t, append(flags, "gate", "run", "-p", "default-latest", "--with-fuzz")...)
	if code != exitcode.Config {
		t.Fatalf("code = %v, want 20", code)
	}
	if !strings.Contains(e, "reserved") || !strings.Contains(e, "fuzz run --attach") {
		t.Errorf("stderr = %q; it must name the reserved flag and the way to do it today", e)
	}
}

// Spec §6.3 puts all three under `gate`. A stale top-level `fbt plan` would keep working silently
// and the two spellings would drift.
func TestPlanAndUpgradeAreReachableOnlyUnderGate(t *testing.T) {
	_, flags := gateFixture(t, cleanGate, cleanCase)

	if code, _, _ := runReal(t, append(flags, "plan", "-p", "default-latest")...); code != exitcode.Config {
		t.Errorf("top-level `plan` returned %v; it must be gone", code)
	}
	if code, _, _ := runReal(t, append(flags, "upgrade", "run")...); code != exitcode.Config {
		t.Errorf("top-level `upgrade` returned %v; it must be gone", code)
	}
	if code, _, e := runReal(t, append(flags, "gate", "plan", "-p", "default-latest")...); code != exitcode.OK {
		t.Errorf("`gate plan` returned %v (%s)", code, e)
	}
}

// A run must leave a durable account of itself. Before this the events lived only in memory and
// evaporated when the process exited, unless the operator happened to pick --output jsonl AND
// redirect it -- so `fbt report` had nothing to read and a four-minute round that built a chain
// left no record at all.
func TestARunWritesItsOwnTranscript(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	writeCase(t, ti, "live.case", "active")

	code, out, e := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v (%s)", code, e)
	}
	var doc GateDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(doc.Workspace, "events.jsonl"))
	if err != nil {
		t.Fatalf("the run left no transcript: %v", err)
	}
	for _, want := range []string{`"ev":"run_started"`, `"ev":"scenario_finished"`, `"ev":"run_finished"`} {
		if !strings.Contains(string(body), want) {
			t.Errorf("transcript is missing %s:\n%s", want, body)
		}
	}
}

// The report is a VIEW of the run: it reads the transcript and never re-runs or re-judges. It also
// exits 0 whatever the run's verdict was -- a CI step that renders the account of a failure must
// not itself fail for having rendered it.
func TestReportReadsTheRunAndExitsZeroOnAFailedOne(t *testing.T) {
	ti, flags := gateFixture(t, "event_set_outcome gate_fail\nexit 1\n", cleanCase)
	writeCase(t, ti, "a.case", "active")

	if code, _, _ := runReal(t, append(flags, "gate", "run", "-p", "default-latest")...); code != exitcode.GateFail {
		t.Fatalf("the fixture run should have failed with 10, got %v", code)
	}
	code, out, e := runReal(t, append(flags, "report")...)
	if code != exitcode.OK {
		t.Fatalf("report on a failed run returned %v (%s)", code, e)
	}
	if !strings.Contains(out, "exit 10") {
		t.Errorf("report does not carry the run's own verdict:\n%s", out)
	}
}

// With no --run-id the newest run is the one meant. Getting the order backwards would silently
// report on the oldest run on the machine, which on a CI box is months old.
func TestReportDefaultsToTheNewestRun(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	writeCase(t, ti, "a.case", "active")
	_, first, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)
	_, second, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)

	var a, b GateDoc
	_ = json.Unmarshal([]byte(first), &a)
	_ = json.Unmarshal([]byte(second), &b)
	if a.RunID == b.RunID {
		t.Fatal("the two runs share an id")
	}
	_, out, _ := runReal(t, append(flags, "report")...)
	if !strings.Contains(out, b.RunID) {
		t.Errorf("report picked %q, want the newer run %s", out, b.RunID)
	}
	_ = ti
}
