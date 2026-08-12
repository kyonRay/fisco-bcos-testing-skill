package cli

import (
	"bytes"
	"encoding/json"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/testinstall"
)

// stubEngine installs scripts that speak the real fd 3 protocol but build nothing. These tests
// drive the ORCHESTRATION -- the order of the checks, the continue policy, the reservation
// lifecycle -- which is exactly the part a live chain would make impossible to test.
func stubEngine(t *testing.T, ti testinstall.Install, gateBody, caseBody string) {
	t.Helper()
	lib := `source "$(dirname "$0")/event_lib.sh"` + "\n"
	// The real event_lib.sh, so the protocol under test is the shipped one.
	src, err := os.ReadFile("../../scripts/event_lib.sh")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ti.Scripts(), "event_lib.sh"), src, 0o644); err != nil {
		t.Fatal(err)
	}
	ti.WriteScript(t, "gate.sh", lib+"event_begin_command gate.sh\n"+gateBody)
	ti.WriteScript(t, "run_case.sh", lib+"event_begin_command run_case.sh\n"+caseBody)
	ti.WriteScript(t, "cluster_down.sh", lib+"event_begin_command cluster_down.sh\necho stopped\n")
}

// gateFixture points fbt at a throwaway install whose config satisfies the whole doctor matrix,
// so a test can fail for the reason it is about rather than for a missing java.
func gateFixture(t *testing.T, gateBody, caseBody string) (testinstall.Install, []string) {
	t.Helper()
	ti := testinstall.New(t)
	stubEngine(t, ti, gateBody, caseBody)

	// Every path the matrix wants, pointing at things that exist.
	for _, d := range []string{"repo", "console", "jsd", "build", "tools"} {
		if err := os.MkdirAll(filepath.Join(ti.Root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"repo/fisco-bcos", "tools/tamper.sh"} {
		if err := os.WriteFile(filepath.Join(ti.Root, f), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	java := "/usr/bin/java"
	if _, err := os.Stat(java); err != nil {
		java = filepath.Join(ti.Root, "repo/fisco-bcos") // any existing file: the check is existence
	}
	cfg := ti.WriteConfig(t, "repo:\n  root: "+filepath.Join(ti.Root, "repo")+"\n"+
		"tools:\n"+
		"  fisco_bin: "+filepath.Join(ti.Root, "repo/fisco-bcos")+"\n"+
		"  console_dir: "+filepath.Join(ti.Root, "console")+"\n"+
		"  java_bin: "+java+"\n"+
		"  tamper_helper: "+filepath.Join(ti.Root, "tools/tamper.sh")+"\n"+
		"  build_dir: "+filepath.Join(ti.Root, "build")+"\n"+
		"  web3_private_key: '0xabc'\n"+
		"jsd:\n  dir: "+filepath.Join(ti.Root, "jsd")+"\n")
	return ti, []string{"--engine-dir", ti.Root, "--state-dir", ti.State, "--config", cfg}
}

func writeCase(t *testing.T, ti testinstall.Install, name, status string) {
	t.Helper()
	p := filepath.Join(ti.Root, "share", "fbt", "cases", name)
	body := "[case]\nstatus = " + status + "\nprofile = default-latest\n" +
		"input = true\nexpect_oracle = pass\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

const cleanGate = `echo "gate running"
printf '{"schema_version":"1.0.0","ev":"scenario_finished","name":"ut","result":"pass"}\n' >&3
printf '{"schema_version":"1.0.0","ev":"scenario_finished","name":"malformed","result":"pass"}\n' >&3
event_set_outcome pass
`

const cleanCase = `printf '{"schema_version":"1.0.0","ev":"case_replayed","file":"c","result":"pass"}\n' >&3
event_set_outcome pass
`

func TestACleanGateRunReportsPassAndExitsZero(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	writeCase(t, ti, "live.case", "active")

	code, out, errOut := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	var doc GateDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, out)
	}
	if doc.Exit != 0 || doc.RunID == "" || doc.Workspace == "" {
		t.Errorf("doc = %+v", doc)
	}
	if len(doc.Scenarios) != 2 || doc.Scenarios[0].Name != "ut" {
		t.Errorf("scenarios = %+v; they must come from the event stream", doc.Scenarios)
	}
	if len(doc.Cases) != 1 || doc.Cases[0].Result != "pass" {
		t.Errorf("cases = %+v", doc.Cases)
	}
	// The workspace really exists, and the reservation was released when the run ended.
	if st, err := os.Stat(doc.Workspace); err != nil || !st.IsDir() {
		t.Errorf("workspace %s: %v", doc.Workspace, err)
	}
	entries, _ := os.ReadDir(filepath.Join(ti.State, "clusters"))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			t.Errorf("the reservation %s outlived the run; the next run would be refused", e.Name())
		}
	}
}

// A gate failure is a RESULT. Stopping at the first one throws away the rest of the picture the
// operator came for, so the sweep continues by default.
func TestAGateFailureStillSweepsTheRemainingCases(t *testing.T) {
	ti, flags := gateFixture(t, "event_set_outcome gate_fail\nexit 1\n", cleanCase)
	writeCase(t, ti, "a.case", "active")
	writeCase(t, ti, "b.case", "active")

	code, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)
	if code != exitcode.GateFail {
		t.Fatalf("code = %v, want 10\n%s", code, out)
	}
	var doc GateDoc
	_ = json.Unmarshal([]byte(out), &doc)
	if len(doc.Cases) != 2 {
		t.Errorf("%d cases ran after the gate failed, want both", len(doc.Cases))
	}
}

// ...and --fail-fast is what stops it, so the two behaviours cannot be confused for one another.
func TestFailFastStopsTheSweepAtTheFirstGateFailure(t *testing.T) {
	ti, flags := gateFixture(t, "event_set_outcome gate_fail\nexit 1\n", cleanCase)
	writeCase(t, ti, "a.case", "active")
	writeCase(t, ti, "b.case", "active")

	_, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest", "--fail-fast")...)...)
	var doc GateDoc
	_ = json.Unmarshal([]byte(out), &doc)
	skipped := 0
	for _, c := range doc.Cases {
		if c.Result == "skip" && c.Skip == "fail_fast" {
			skipped++
		}
	}
	if skipped != 2 {
		t.Errorf("%d cases skipped, want both:\n%s", skipped, out)
	}
}

// Spec §10: after a 20/30/40 the later cases are measuring something other than the chain, so
// continuing would produce results that look like findings and are not.
func TestAnInfraFailureStopsTheSweep(t *testing.T) {
	ti, flags := gateFixture(t, "event_set_outcome infra_error\nexit 1\n", cleanCase)
	writeCase(t, ti, "a.case", "active")

	code, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)
	if code != exitcode.Infra {
		t.Fatalf("code = %v, want 30\n%s", code, out)
	}
	var doc GateDoc
	_ = json.Unmarshal([]byte(out), &doc)
	if len(doc.Cases) != 1 || doc.Cases[0].Result != "skip" {
		t.Errorf("cases = %+v; the sweep must have stopped", doc.Cases)
	}
	if !strings.Contains(doc.Cases[0].Skip, "infra") {
		t.Errorf("skip reason = %q; it must say why", doc.Cases[0].Skip)
	}
}

// Only active fixtures are swept. A pending one tracks an unfixed defect, so sweeping it would
// make every gate round permanently red for something already known.
func TestPendingAndExampleCasesAreNeverSwept(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	writeCase(t, ti, "known.case", "pending")
	writeCase(t, ti, "demo.case", "example")

	code, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "gate", "run", "-p", "default-latest")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v\n%s", code, out)
	}
	var doc GateDoc
	_ = json.Unmarshal([]byte(out), &doc)
	if len(doc.Cases) != 0 {
		t.Errorf("cases = %+v, want none swept", doc.Cases)
	}
}

// One malformed fixture must surface BEFORE a chain is started, not after.
func TestAMalformedCaseIsRefusedBeforeTheEngineRuns(t *testing.T) {
	ti, flags := gateFixture(t, "touch "+filepath.Join(t.TempDir(), "ran")+"\n", cleanCase)
	marker := filepath.Join(ti.Root, "gate-ran")
	stubEngine(t, ti, "touch "+marker+"\n", cleanCase)
	// No status: the one thing that must never be defaulted.
	p := filepath.Join(ti.Root, "share", "fbt", "cases", "bad.case")
	if err := os.WriteFile(p, []byte("[case]\nprofile = p\ninput = i\nexpect_oracle = pass\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, _, errOut := runReal(t, append(flags, "gate", "run", "-p", "default-latest")...)
	if code != exitcode.Config {
		t.Fatalf("code = %v, want 20 (%s)", code, errOut)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("gate.sh ran despite a malformed fixture; the parse must precede the chain")
	}
}

// A cluster that is already active blocks a second run, and the message has to say how to clear it.
func TestASecondRunIsRefusedWhileAClusterIsRegistered(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	// A registration whose node is this very test process, so it is unambiguously alive.
	regDir := filepath.Join(ti.State, "clusters")
	if err := os.MkdirAll(regDir, 0o755); err != nil {
		t.Fatal(err)
	}
	entry := `{"run_id":"other","workspace":"/ws/other","ports":[{"name":"p2p","base":30300,"count":4}],
	  "nodes":[{"name":"node0","pid":` + itoa(os.Getpid()) + `}]}`
	if err := os.WriteFile(filepath.Join(regDir, "other.json"), []byte(entry), 0o644); err != nil {
		t.Fatal(err)
	}
	code, _, errOut := runReal(t, append(flags, "gate", "run", "-p", "default-latest")...)
	if code != exitcode.Config {
		t.Fatalf("code = %v, want 20", code)
	}
	if !strings.Contains(errOut, "cluster down") {
		t.Errorf("stderr = %q; it must say how to clear the blocking cluster", errOut)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// ---------------------------------------------------------------------------
// plan, doctor, case list, cluster ls
// ---------------------------------------------------------------------------

// A plan that shows only what runs cannot answer the question people bring to it: why is my
// fixture not being tested?
func TestPlanNamesTheSkippedCasesAndWhy(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	writeCase(t, ti, "live.case", "active")
	writeCase(t, ti, "known.case", "pending")

	code, out, errOut := runReal(t, append([]string{"--output", "json"},
		append(flags, "plan", "-p", "default-latest")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v (%s)", code, errOut)
	}
	var doc PlanDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	byName := map[string]planCase{}
	for _, c := range doc.Cases {
		byName[c.Name] = c
	}
	if !byName["live.case"].Swept {
		t.Error("an active case is not planned to run")
	}
	if byName["known.case"].Swept || !strings.Contains(byName["known.case"].Reason, "pending") {
		t.Errorf("pending case = %+v; it must be shown as skipped, with the reason",
			byName["known.case"])
	}
	if len(doc.Ports) != 3 {
		t.Errorf("ports = %+v; the plan must show what it would reserve", doc.Ports)
	}
}

// A plan starts nothing. If it did, `plan` would cost as much as the run it describes.
func TestPlanTouchesNothing(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	marker := filepath.Join(ti.Root, "gate-ran")
	// Re-stub gate.sh so that RUNNING it leaves a trace this test can see.
	stubEngine(t, ti, "touch "+marker+"\n", cleanCase)

	if code, _, e := runReal(t, append(flags, "plan", "-p", "default-latest")...); code != exitcode.OK {
		t.Fatalf("code = %v (%s)", code, e)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("plan ran the engine")
	}
	if _, err := os.Stat(filepath.Join(ti.State, "runs")); err == nil {
		t.Error("plan created a workspace; every printed plan would leave an empty run behind")
	}

	// The negative half: the same marker DOES appear on a real run, so the assertion above is
	// about plan's restraint and not about a marker that could never have been written.
	if code, _, e := runReal(t, append(flags, "gate", "run", "-p", "default-latest")...); code != exitcode.OK {
		t.Fatalf("the control run failed: %v (%s)", code, e)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Errorf("gate run did not touch the marker either, so the check above proves nothing: %v", err)
	}
}

// doctor must exit with the code the real run would exit with, or a CI preflight step learns
// nothing from it.
func TestDoctorExitsWithTheCodeTheRunWouldHave(t *testing.T) {
	_, flags := gateFixture(t, cleanGate, cleanCase)
	if code, _, e := runReal(t, append(flags, "doctor", "--command", "gate")...); code != exitcode.OK {
		t.Fatalf("a complete fixture failed doctor: %v (%s)", code, e)
	}

	// Now break one path and watch it become 30 rather than 20: it IS configured, it is just gone.
	ti2 := testinstall.New(t)
	stubEngine(t, ti2, cleanGate, cleanCase)
	cfg := ti2.WriteConfig(t, "tools:\n  fisco_bin: /definitely/not/here\n")
	code, _, _ := runReal(t, "--engine-dir", ti2.Root, "--state-dir", ti2.State,
		"--config", cfg, "doctor", "--command", "gate")
	if code != exitcode.Infra {
		t.Errorf("code = %v, want 30", code)
	}

	// Teardown checks nothing, even on the same broken fixture.
	code, _, _ = runReal(t, "--engine-dir", ti2.Root, "--state-dir", ti2.State,
		"--config", cfg, "doctor", "--command", "cluster-down")
	if code != exitcode.OK {
		t.Errorf("teardown was refused for missing dependencies: %v", code)
	}
}

func TestCaseListCountsWhatTheGateWillActuallyRun(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	writeCase(t, ti, "live.case", "active")
	writeCase(t, ti, "known.case", "pending")
	writeCase(t, ti, "demo.case", "example")

	code, out, e := runReal(t, append([]string{"--output", "json"},
		append(flags, "case", "list")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v (%s)", code, e)
	}
	var doc caseListDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Cases) != 3 || doc.Swept != 1 || doc.Pending != 1 {
		t.Errorf("doc = %+v; 3 cases, 1 swept, 1 pending", doc)
	}
}

func TestClusterLsReportsWhatItReclaimed(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	regDir := filepath.Join(ti.State, "clusters")
	if err := os.MkdirAll(regDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// pid 2^22-1 is above every real pid on Linux and macOS, so this entry is unambiguously stale.
	dead := `{"run_id":"dead","workspace":"/ws/dead","ports":[{"name":"p2p","base":30300,"count":4}],
	  "nodes":[{"name":"node0","pid":4194303}]}`
	if err := os.WriteFile(filepath.Join(regDir, "dead.json"), []byte(dead), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out, e := runReal(t, append([]string{"--output", "json"},
		append(flags, "cluster", "ls")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v (%s)", code, e)
	}
	var doc clusterDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	// Reported, not silent: an operator must be able to tell "fbt cleaned up after a crash" from
	// "somebody tore down my chain".
	if len(doc.Reclaimed) != 1 || doc.Reclaimed[0] != "dead" {
		t.Errorf("reclaimed = %v", doc.Reclaimed)
	}
	if len(doc.Clusters) != 0 {
		t.Errorf("clusters = %+v, want none left", doc.Clusters)
	}
}

// Spec §11 puts evidence_path in the failure envelope, and it is the only field that tells an
// operator where to look. A failure that happened with a workspace open and reports no path leaves
// them to guess which of the run directories under the state dir was theirs.
func TestAFailureInsideARunCarriesItsEvidencePath(t *testing.T) {
	ti, flags := gateFixture(t, cleanGate, cleanCase)
	// A .case whose profile does not resolve: the engine gets far enough that a workspace exists.
	p := filepath.Join(ti.Root, "share", "fbt", "cases", "broken.case")
	if err := os.WriteFile(p, []byte("[case]\nstatus = active\nprofile = /no/such.profile\n"+
		"input = true\nexpect_oracle = pass\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// run_case.sh here is the stub, so drive the failure through the host instead: an engine script
	// that reports config_error with a workspace open.
	stubEngine(t, ti, cleanGate, "event_set_outcome config_error\nexit 2\n")

	code, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "case", "run", "broken.case")...)...)
	if code != exitcode.Config {
		t.Fatalf("code = %v, want 20\n%s", code, out)
	}

	// And the same failure in human mode names the workspace on stderr.
	_, _, errOut := runReal(t, append(flags, "case", "run", "broken.case")...)
	_ = errOut
	// The run document carries the run id either way, which is what locates the workspace.
	var doc caseRunDoc
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, out)
	}
	if doc.RunID == "" {
		t.Error("the result names no run, so the workspace cannot be found afterwards")
	}
	if _, err := os.Stat(filepath.Join(ti.State, "runs", doc.RunID)); err != nil {
		t.Errorf("the workspace named by run_id %s does not exist: %v", doc.RunID, err)
	}
}

// emitErrorAt is the mechanism; this pins its contract directly, since the path only appears on
// failure routes that are awkward to reach through a whole command.
func TestTheErrorEnvelopeCarriesTheEvidencePath(t *testing.T) {
	var out, errOut bytes.Buffer
	emitErrorAt(&out, &errOut, OutputJSON, fbterr.Infraf("the chain never came up"), "/state/runs/R1")
	var doc map[string]interface{}
	if err := json.Unmarshal(out.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	if doc["evidence_path"] != "/state/runs/R1" || doc["exit"] != float64(30) {
		t.Errorf("doc = %v", doc)
	}

	// A static command has no workspace, and an empty path must be OMITTED rather than reported as
	// an empty string a consumer would then try to open.
	//
	// A FRESH map: json.Unmarshal MERGES into a non-nil map rather than replacing it, so reusing
	// `doc` here would carry the previous document's evidence_path forward and this assertion
	// would fail against correct code.
	out.Reset()
	doc = map[string]interface{}{}
	emitErrorAt(&out, &errOut, OutputJSON, fbterr.Configf("bad flag"), "")
	if err := json.Unmarshal(out.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	if _, present := doc["evidence_path"]; present {
		t.Errorf("evidence_path is present with no workspace: %v", doc)
	}

	// Human mode must show it too, or the field only helps machines.
	errOut.Reset()
	emitErrorAt(&out, &errOut, OutputHuman, fbterr.Infraf("boom"), "/state/runs/R2")
	if !strings.Contains(errOut.String(), "/state/runs/R2") {
		t.Errorf("stderr = %q; a human needs the path most of all", errOut.String())
	}
}
