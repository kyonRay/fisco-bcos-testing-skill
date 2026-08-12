package doctor

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// fakeProbe makes every dependency's presence an input, so the matrix can be tested without
// installing java, node or a FISCO checkout.
type fakeProbe struct {
	path    map[string]bool
	files   map[string]bool
	bash    int
	modules map[string]bool
}

func (f fakeProbe) LookPath(exe string) bool { return f.path[exe] }
func (f fakeProbe) Exists(p string) bool     { return f.files[p] }
func (f fakeProbe) BashMajor() int           { return f.bash }

func (f fakeProbe) NodeModule(_, name string) bool { return f.modules[name] }

func everything() fakeProbe {
	return fakeProbe{
		path:    map[string]bool{"curl": true, "pgrep": true, "node": true},
		files:   map[string]bool{},
		bash:    5,
		modules: map[string]bool{"viem": true},
	}
}

// fullConfig supplies every path the gate matrix asks for, and marks each as present.
func fullConfig(p fakeProbe) (map[string]string, fakeProbe) {
	cfg := map[string]string{
		"repo.root":              "/repo",
		"tools.fisco_bin":        "/repo/fisco-bcos",
		"tools.console_dir":      "/console",
		"tools.java_bin":         "/usr/bin/java",
		"tools.tamper_helper":    "/tools/tamper.sh",
		"tools.web3_private_key": "0xdeadbeef",
		"jsd.dir":                "/jsd",
		"tools.build_dir":        "/repo/build",
	}
	for _, v := range cfg {
		if strings.HasPrefix(v, "/") {
			p.files[v] = true
		}
	}
	return cfg, p
}

func TestAFullyEquippedMachinePassesTheGateMatrix(t *testing.T) {
	plan, err := Plan("gate", nil)
	if err != nil {
		t.Fatal(err)
	}
	cfg, p := fullConfig(everything())
	rep, err := Check(plan, cfg, p)
	if err != nil {
		t.Fatalf("Check: %v", err)
	}
	if rep.Exit != 0 {
		t.Errorf("Exit = %d", rep.Exit)
	}
	for _, f := range rep.Deps {
		if !f.Present {
			t.Errorf("%s reported missing on a complete machine: %s", f.Name, f.Detail)
		}
	}
}

// Spec §5: not configured is 20 (edit fbt.yaml), configured-but-absent is 30 (fix the machine).
// Collapsing the two sends the operator to the wrong place.
func TestUnsetIsConfigAndAbsentIsInfra(t *testing.T) {
	plan := []Requirement{{Name: "bin", Kind: KindPath, ConfigKey: "tools.fisco_bin", Why: "w"}}

	rep, err := Check(plan, map[string]string{}, everything())
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassConfig || rep.Exit != 20 {
		t.Errorf("unset: class=%v exit=%d, want config/20", c, rep.Exit)
	}
	if rep.Deps[0].Class != "config" || !strings.Contains(rep.Deps[0].Detail, "not set") {
		t.Errorf("unset finding = %+v", rep.Deps[0])
	}

	rep, err = Check(plan, map[string]string{"tools.fisco_bin": "/nope"}, everything())
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassInfra || rep.Exit != 30 {
		t.Errorf("absent: class=%v exit=%d, want infra/30", c, rep.Exit)
	}
	if !strings.Contains(rep.Deps[0].Detail, "/nope") {
		t.Errorf("absent finding = %+v; it must name the path that is not there", rep.Deps[0])
	}
}

// Checking dependencies of work that was not selected is how a tool refuses to run for reasons
// that have nothing to do with the request.
func TestScenarioFilteringDropsUnselectedDependencies(t *testing.T) {
	plan, err := Plan("gate", []string{"malformed"})
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, r := range plan {
		names[r.Name] = true
	}
	for _, want := range []string{"bash4", "curl", "node-binary", "tamper-helper"} {
		if !names[want] {
			t.Errorf("--scenarios malformed dropped %s, which it needs", want)
		}
	}
	for _, unwanted := range []string{"node-runtime", "jsd", "ut-binaries", "web3-key"} {
		if names[unwanted] {
			t.Errorf("--scenarios malformed still demands %s", unwanted)
		}
	}

	// And with Node genuinely absent, a malformed-only round still passes while a full round does
	// not -- which is the whole point of the filter.
	p := everything()
	p.path["node"] = false
	cfg, p := fullConfig(p)
	if _, err := Check(plan, cfg, p); err != nil {
		t.Errorf("a malformed-only round was refused for a missing Node: %v", err)
	}
	full, _ := Plan("gate", nil)
	if _, err := Check(full, cfg, p); err == nil {
		t.Error("a full round was allowed with Node missing")
	}
}

// Spec §5, in as many words: never refuse to stop a cluster because java or Viem is missing. A
// half-installed machine with a stuck cluster is exactly when `cluster down` has to work.
func TestTeardownChecksNothingAtAll(t *testing.T) {
	bare := fakeProbe{path: map[string]bool{}, files: map[string]bool{}, bash: 3}
	for _, cmd := range []string{"cluster-down", "cluster-ls"} {
		plan, err := Plan(cmd, nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(plan) != 0 {
			t.Errorf("%s checks %d dependencies, want none", cmd, len(plan))
		}
		if rep, err := Check(plan, nil, bare); err != nil || rep.Exit != 0 {
			t.Errorf("%s was refused on a bare machine: %v", cmd, err)
		}
	}
}

// fuzz attaches to a cluster somebody else built, so demanding the checkout and console would
// refuse a run that needs neither.
func TestFuzzDoesNotDemandTheCheckoutOrConsole(t *testing.T) {
	plan, err := Plan("fuzz", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range plan {
		if r.ConfigKey == "repo.root" || r.ConfigKey == "tools.console_dir" {
			t.Errorf("fuzz demands %s", r.ConfigKey)
		}
	}
	cfg := map[string]string{"tools.java_bin": "/j", "tools.fuzz_jar": "/f.jar"}
	p := everything()
	p.files["/j"], p.files["/f.jar"] = true, true
	if _, err := Check(plan, cfg, p); err != nil {
		t.Errorf("fuzz was refused with everything it actually needs: %v", err)
	}
}

// Stock macOS ships bash 3.2, on which every engine script dies with an obscure parse error. It is
// checked up front so that failure arrives as a sentence instead of mid-round.
func TestBashThreeIsRefusedUpFront(t *testing.T) {
	p := everything()
	p.bash = 3
	cfg, p := fullConfig(p)
	plan, _ := Plan("gate", nil)
	_, err := Check(plan, cfg, p)
	if err == nil {
		t.Fatal("bash 3.2 was accepted")
	}
	if !strings.Contains(err.Error(), "brew install bash") {
		t.Errorf("err = %v; it must say how to fix it", err)
	}
}

// Both kinds missing at once must report BOTH, and exit with the more severe code. Reporting only
// the first kind means the operator fixes it, re-runs, and meets the second -- twice the round
// trips for one broken machine.
func TestBothKindsOfFailureAreReportedTogether(t *testing.T) {
	plan := []Requirement{
		{Name: "unset", Kind: KindPath, ConfigKey: "repo.root", Why: "w"},
		{Name: "absent", Kind: KindPath, ConfigKey: "tools.fisco_bin", Why: "w"},
	}
	rep, err := Check(plan, map[string]string{"tools.fisco_bin": "/nope"}, everything())
	if rep.Exit != 30 {
		t.Errorf("Exit = %d, want 30 (infra outranks config in §10's priority)", rep.Exit)
	}
	if !strings.Contains(err.Error(), "repo.root") || !strings.Contains(err.Error(), "/nope") {
		t.Errorf("err = %v; both problems must appear", err)
	}
}

func TestAnUnknownCommandIsAHostError(t *testing.T) {
	_, err := Plan("teleport", nil)
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassHost {
		t.Errorf("class = %v; a command with no matrix row is fbt's own omission", c)
	}
}

// Every scenario named in the matrix must be one gate.sh actually knows, or the filter silently
// never matches and the dependency is never checked.
func TestEveryScenarioNameInTheMatrixIsReal(t *testing.T) {
	known := map[string]bool{"ut": true, "dual_rpc": true, "malformed": true, "jsd": true}
	for cmd, reqs := range matrix {
		for _, r := range reqs {
			for _, s := range r.Scenarios {
				if !known[s] {
					t.Errorf("%s/%s is gated on scenario %q, which is not a gate scenario family",
						cmd, r.Name, s)
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The real probe. Without these the shipped implementation is unexercised.
// ---------------------------------------------------------------------------

func TestTheRealProbeFindsAndMissesTheRightThings(t *testing.T) {
	p := OSProbe{}
	if !p.LookPath("sh") {
		t.Error("sh was not found on PATH")
	}
	if p.LookPath("fbt-definitely-not-a-real-program") {
		t.Error("a nonexistent program was found")
	}
	if !p.Exists("/") || p.Exists("/nonexistent-fbt-path-xyz") {
		t.Error("Exists is wrong about / or about a path that is not there")
	}
	if _, err := exec.LookPath("bash"); err == nil {
		if m := p.BashMajor(); m < 3 {
			t.Errorf("BashMajor = %d; bash is installed, so this cannot be right", m)
		}
	}
}

func TestBashVersionParsing(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want int
	}{
		{"GNU bash, version 5.2.15(1)-release (aarch64-apple-darwin23)", 5},
		{"GNU bash, version 3.2.57(1)-release (arm64-apple-darwin24)", 3},
		{"GNU bash, version 12.0.0", 12},
		{"something else entirely", 0},
		{"GNU bash, version x.y", 0},
		// A localized banner. This machine really does print this, and a parser that looks for
		// the English word "version" reports 0 -- refusing a machine with bash 5.3 installed.
		{"GNU bash\uff0c\u7248\u672c 5.3.15(1)-release (aarch64-apple-darwin25.4.0)", 5},
		{"GNU bash, Version 4.4.20(1)-release", 4},
		// The copyright year on line 2 must never be mistaken for a version.
		{"no digits here at all\nCopyright (C) 2025 Free Software Foundation", 0},
	} {
		if got := parseBashMajor(tc.in); got != tc.want {
			t.Errorf("parseBashMajor(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// Several built-in defaults are RELATIVE -- tools.console_dir is "console/dist", mirroring the
// engine's own ${CONSOLE_DIR:-console/dist} -- and the engine resolves those against ITS working
// directory, the FISCO checkout. Checking them against the host's cwd reports "console/dist does
// not exist" on a machine where the engine would find it immediately: a false red that refuses a
// perfectly good run.
func TestRelativePathsResolveAgainstTheEnginesWorkingDirectory(t *testing.T) {
	plan := []Requirement{{Name: "console", Kind: KindPath, ConfigKey: "tools.console_dir", Why: "w"}}
	cfg := map[string]string{"tools.console_dir": "console/dist"}
	p := everything()
	p.files["/repo/console/dist"] = true // it exists where the ENGINE will look

	if _, err := CheckIn("/repo", plan, cfg, p); err != nil {
		t.Errorf("a relative default was checked against the wrong base: %v", err)
	}
	// ...and it is still a real failure when it is genuinely absent under that base.
	if _, err := CheckIn("/elsewhere", plan, cfg, p); err == nil {
		t.Error("a path missing under the engine's cwd was accepted")
	}
	// An absolute value is never rebased.
	abs := map[string]string{"tools.console_dir": "/opt/console"}
	p.files["/opt/console"] = true
	if _, err := CheckIn("/repo", plan, abs, p); err != nil {
		t.Errorf("an absolute path was rebased: %v", err)
	}
	// "not configured" must stay 20, not become "configured, pointing at the base directory".
	rep, err := CheckIn("/repo", plan, map[string]string{}, p)
	if err == nil || rep.Deps[0].Class != "config" {
		t.Errorf("an unset key with a base became %+v; it must still be a config error", rep.Deps[0])
	}
}

// tools.java_bin defaults to "java", a COMMAND NAME. The engine runs ${JAVA_BIN:-java} through a
// shell, which resolves it on PATH -- so treating it as a relative path and looking for
// <repo>/java reports a missing dependency on every machine where java is installed normally.
func TestABareCommandNameIsLookedUpOnPathNotUnderTheRepo(t *testing.T) {
	plan := []Requirement{{Name: "java", Kind: KindPath, ConfigKey: "tools.java_bin", Why: "w"}}
	p := everything()
	p.path["java"] = true // on PATH, as a normal install puts it
	// Nothing at /repo/java, deliberately.
	if _, err := CheckIn("/repo", plan, map[string]string{"tools.java_bin": "java"}, p); err != nil {
		t.Errorf("a bare command name was looked for under the repo: %v", err)
	}
	// Absent from PATH is still infra, with a message that says PATH rather than a path.
	p.path["java"] = false
	rep, err := CheckIn("/repo", plan, map[string]string{"tools.java_bin": "java"}, p)
	if err == nil {
		t.Fatal("java missing from PATH was accepted")
	}
	if !strings.Contains(rep.Deps[0].Detail, "not on PATH") {
		t.Errorf("detail = %q", rep.Deps[0].Detail)
	}
	// A value that IS a path keeps the path treatment.
	p.files["/opt/jdk/bin/java"] = true
	if _, err := CheckIn("/repo", plan, map[string]string{"tools.java_bin": "/opt/jdk/bin/java"}, p); err != nil {
		t.Errorf("an explicit path was not honoured: %v", err)
	}
}

// A missing npm package is the machine's problem, not the chain's. Before this was checked, viem's
// absence surfaced four minutes into a run as a dual_rpc scenario FAILURE -- exit 10, "the chain
// failed the gate" -- for a release candidate whose web3 leg had never executed.
func TestAMissingNodeModuleIsInfraNotAGateFailure(t *testing.T) {
	plan, err := Plan("gate", []string{"dual_rpc"})
	if err != nil {
		t.Fatal(err)
	}
	cfg, p := fullConfig(everything())
	p.modules = map[string]bool{} // node is installed; viem is not
	_, err = CheckIn("/repo", plan, cfg, p)
	if err == nil {
		t.Fatal("a machine with no viem passed the dual_rpc preflight")
	}
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassInfra {
		t.Errorf("class = %v, want infra (exit 30)", c)
	}
	if !strings.Contains(err.Error(), "viem") {
		t.Errorf("err = %v, want it to name the package", err)
	}
}
