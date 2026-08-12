package cases

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

const good = `# a comment
[case]
status = active
profile = default-latest
input = console.sh call HelloWorld get
expect_oracle = pass
`

func TestAWellFormedCaseParses(t *testing.T) {
	c, err := Parse(write(t, t.TempDir(), "ok.case", good))
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != StatusActive || c.Profile != "default-latest" || c.Expect != ExpectPass {
		t.Errorf("%+v", c)
	}
	if c.Input != "console.sh call HelloWorld get" {
		t.Errorf("Input = %q", c.Input)
	}
	if c.Name != "ok.case" || !c.Sweepable() {
		t.Errorf("Name=%q Sweepable=%v", c.Name, c.Sweepable())
	}
}

// An input is a shell command: it routinely contains '=', quotes, JSON and URLs. A parser that
// splits on every '=' or strips quotes would corrupt the very payload the fixture exists to replay.
func TestTheInputSurvivesVerbatim(t *testing.T) {
	raw := `curl -sS -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":["a=b"]}' http://127.0.0.1:20200?x=1`
	c, err := Parse(write(t, t.TempDir(), "x.case",
		"[case]\nstatus = pending\nprofile = p\nexpect_oracle = reject\ninput = "+raw+"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Input != raw {
		t.Errorf("input was mangled:\n got %q\nwant %q", c.Input, raw)
	}
}

// The false green this whole field exists to prevent: defaulting a missing status to "example"
// makes real regression fixtures silently stop running after an upgrade, while the gate keeps
// reporting green (spec §6.4).
func TestAMissingStatusIsRefusedNotDefaulted(t *testing.T) {
	_, err := Parse(write(t, t.TempDir(), "n.case",
		"[case]\nprofile = p\ninput = i\nexpect_oracle = pass\n"))
	if err == nil {
		t.Fatal("a case with no status was accepted")
	}
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassConfig {
		t.Errorf("class = %v, want config (exit 20)", c)
	}
	if !strings.Contains(err.Error(), "status is required") {
		t.Errorf("err = %v", err)
	}
}

func TestEveryRequiredFieldAndValueIsChecked(t *testing.T) {
	for _, tc := range []struct{ name, body, want string }{
		{"bad status", "[case]\nstatus = later\nprofile = p\ninput = i\nexpect_oracle = pass\n", "not one of"},
		{"no profile", "[case]\nstatus = active\ninput = i\nexpect_oracle = pass\n", "profile is required"},
		{"no input", "[case]\nstatus = active\nprofile = p\nexpect_oracle = pass\n", "input is required"},
		{"no expect", "[case]\nstatus = active\nprofile = p\ninput = i\n", "expect_oracle is required"},
		{"bad expect", "[case]\nstatus = active\nprofile = p\ninput = i\nexpect_oracle = crash\n", "not pass or reject"},
		{"no section", "status = active\n", "before the [case] section"},
		{"other section", "[genesis]\nx = 1\n", "unknown section"},
		{"not a pair", "[case]\nstatus\n", "not a key = value"},
		{"unterminated", "[case\n", "unterminated"},
	} {
		_, err := Parse(write(t, t.TempDir(), "b.case", tc.body))
		if err == nil {
			t.Errorf("%s: accepted", tc.name)
			continue
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want it to mention %q", tc.name, err, tc.want)
		}
		if c, _ := fbterr.ClassOf(err); c != fbterr.ClassConfig {
			t.Errorf("%s: class = %v, want config", tc.name, c)
		}
	}
}

// run_case.sh silently ignores unknown keys. fbt does not, on purpose: a mistyped expect_orcale
// there reports "expect_oracle is required" and sends the author hunting for a line that is right
// in front of them.
func TestATypoIsNamedRatherThanSilentlyIgnored(t *testing.T) {
	_, err := Parse(write(t, t.TempDir(), "t.case",
		"[case]\nstatus = active\nprofile = p\ninput = i\nexpect_orcale = pass\n"))
	if err == nil {
		t.Fatal("a typo'd key was ignored, and the case would have run with a field unset")
	}
	if !strings.Contains(err.Error(), "expect_orcale") || !strings.Contains(err.Error(), "did you mean") {
		t.Errorf("err = %v; it must quote the typo and point at the real key", err)
	}
}

// Which duplicate wins would silently decide what the fixture actually tests.
func TestADuplicateKeyIsRefused(t *testing.T) {
	_, err := Parse(write(t, t.TempDir(), "d.case",
		"[case]\nstatus = active\nprofile = a\nprofile = b\ninput = i\nexpect_oracle = pass\n"))
	if err == nil || !strings.Contains(err.Error(), "set twice") {
		t.Errorf("err = %v", err)
	}
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

func TestListUnionsBothDirectoriesAndSortsByName(t *testing.T) {
	root := t.TempDir()
	shipped, state := filepath.Join(root, "shipped"), filepath.Join(root, "state")
	write(t, shipped, "zeta.case", good)
	write(t, shipped, "alpha.case", good)
	write(t, state, "mid.case", strings.Replace(good, "active", "pending", 1))

	all, err := Registry{Shipped: shipped, State: state}.List()
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, c := range all {
		names = append(names, c.Name)
	}
	if strings.Join(names, ",") != "alpha.case,mid.case,zeta.case" {
		t.Errorf("names = %v, want them unioned and sorted", names)
	}
	if all[1].Source != "state" || all[0].Source != "shipped" {
		t.Errorf("sources = %q/%q", all[0].Source, all[1].Source)
	}
	// Only active cases are swept: sweeping a pending one would make the gate permanently red,
	// and it is pending precisely because the defect is not fixed yet.
	swept := Sweep(all)
	if len(swept) != 2 {
		t.Errorf("swept %d cases, want the 2 active ones", len(swept))
	}
	for _, c := range swept {
		if c.Status != StatusActive {
			t.Errorf("%s (%s) was swept", c.Name, c.Status)
		}
	}
}

// A silent winner means a stale state copy replaces a fixture the release shipped, and the gate
// then tests something other than what it reports.
func TestASharedBasenameIsAConflictNotAShadowing(t *testing.T) {
	root := t.TempDir()
	shipped, state := filepath.Join(root, "shipped"), filepath.Join(root, "state")
	write(t, shipped, "same.case", good)
	write(t, state, "same.case", good)

	_, err := Registry{Shipped: shipped, State: state}.List()
	if err == nil {
		t.Fatal("one copy silently won")
	}
	if !strings.Contains(err.Error(), shipped) || !strings.Contains(err.Error(), state) {
		t.Errorf("err = %v; it must name both files", err)
	}
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassConfig {
		t.Errorf("class = %v, want config (exit 20)", c)
	}
}

// One malformed fixture must surface before anything starts a chain, not after.
func TestOneBadCaseFailsTheWholeEnumeration(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "fine.case", good)
	write(t, dir, "broken.case", "[case]\nprofile = p\n")
	if _, err := (Registry{Shipped: dir}).List(); err == nil {
		t.Fatal("a malformed case was skipped instead of reported")
	}
}

func TestFindAcceptsANameASuffixedNameOrAPath(t *testing.T) {
	dir := t.TempDir()
	p := write(t, dir, "target.case", good)
	r := Registry{Shipped: dir}
	for _, spec := range []string{"target", "target.case", p} {
		c, err := r.Find(spec)
		if err != nil {
			t.Errorf("Find(%q): %v", spec, err)
			continue
		}
		if c.Name != "target.case" {
			t.Errorf("Find(%q) = %q", spec, c.Name)
		}
	}
	_, err := r.Find("nope")
	if err == nil || !strings.Contains(err.Error(), "target.case") {
		t.Errorf("err = %v; an unknown name must list what IS available", err)
	}
}

// The two fixtures the repository actually ships have to parse, or the whole flywheel is broken
// before anyone adds a third.
func TestTheRepositorysOwnCasesParse(t *testing.T) {
	all, err := (Registry{Shipped: "../../scenarios"}).List()
	if err != nil {
		t.Fatalf("the shipped fixtures do not parse: %v", err)
	}
	want := map[string]Status{"example.case": StatusExample, "fuzz_seed43_idx11.case": StatusPending}
	if len(all) != len(want) {
		t.Fatalf("found %d cases, want %d", len(all), len(want))
	}
	for _, c := range all {
		if w, ok := want[c.Name]; !ok || c.Status != w {
			t.Errorf("%s has status %q, want %q", c.Name, c.Status, w)
		}
	}
	// Neither shipped fixture is swept today: one is a format example and the other tracks an
	// unfixed defect. A gate round that swept either would be red for reasons that are not the
	// chain's fault.
	if n := len(Sweep(all)); n != 0 {
		t.Errorf("%d shipped cases would be swept, want 0", n)
	}
}
