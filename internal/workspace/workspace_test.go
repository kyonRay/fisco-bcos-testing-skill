package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func TestRunIDsAreUniqueWithinOneSecond(t *testing.T) {
	// A CI matrix starts every job at once. A timestamp-only id would collide, and two runs would
	// then share one workspace.
	now := time.Date(2026, 8, 12, 10, 15, 30, 0, time.UTC)
	seen := map[string]bool{}
	for i := 0; i < 500; i++ {
		id, err := NewRunID(now)
		if err != nil {
			t.Fatal(err)
		}
		if seen[id] {
			t.Fatalf("run id %s handed out twice from the same timestamp", id)
		}
		seen[id] = true
		if !ValidRunID(id) {
			t.Fatalf("generated id %q fails its own validity check", id)
		}
		if !strings.HasPrefix(id, "20260812T101530Z-") {
			t.Fatalf("id %q does not start with the UTC timestamp, so ids do not sort by time", id)
		}
	}
}

// The id reaches fbt from outside (`cluster down --run-id X`) and is joined onto the state
// directory. A traversal here would point a cleanup command at somewhere else entirely.
func TestRunIDValidationRefusesAnythingPathShaped(t *testing.T) {
	for _, bad := range []string{
		"", "..", "../..", "a/b", "/abs", "a\x00b", "a b", "a.b", "a;rm -rf /", strings.Repeat("x", 65),
	} {
		if ValidRunID(bad) {
			t.Errorf("ValidRunID(%q) = true", bad)
		}
	}
	for _, ok := range []string{"20260812T101530Z-AB12CD34", "manual-run_1", "x"} {
		if !ValidRunID(ok) {
			t.Errorf("ValidRunID(%q) = false", ok)
		}
	}
}

func TestLayoutRefusesABadRunIDBeforeTouchingTheDisk(t *testing.T) {
	if _, err := Layout("/state", "../escape"); err == nil {
		t.Fatal("a traversal id was accepted")
	} else if c, _ := fbterr.ClassOf(err); c != fbterr.ClassConfig {
		t.Errorf("class = %v, want config", c)
	}
	// A relative state dir would resolve against the process working directory, while the engine
	// runs with a different one entirely (spec §7.3).
	if _, err := Layout("relative/state", "ok"); err == nil {
		t.Fatal("a relative state directory was accepted")
	}
}

func TestCreateMakesTheWholeLayout(t *testing.T) {
	state := t.TempDir()
	w, err := Create(state, "run-1")
	if err != nil {
		t.Fatal(err)
	}
	if w.Root != filepath.Join(state, "runs", "run-1") {
		t.Errorf("Root = %s", w.Root)
	}
	for _, d := range []string{w.Root, w.Cluster, w.Evidence} {
		st, err := os.Stat(d)
		if err != nil || !st.IsDir() {
			t.Errorf("%s is not a directory: %v", d, err)
		}
	}
	// failures.jsonl is NOT pre-created: failures_lib.sh appends to it, and an existing empty file
	// would make "no defects were recorded" and "the sink was never written" look the same.
	if _, err := os.Stat(w.Failures); !os.IsNotExist(err) {
		t.Errorf("failures.jsonl exists before anything failed: %v", err)
	}
}

// Two runs sharing one workspace would interleave their failures.jsonl rows and build two chains
// in one cluster directory -- and the second would look like it had inherited the first's defects.
func TestCreateRefusesAnExistingWorkspace(t *testing.T) {
	state := t.TempDir()
	if _, err := Create(state, "dup"); err != nil {
		t.Fatal(err)
	}
	_, err := Create(state, "dup")
	if err == nil {
		t.Fatal("the second run silently joined the first one's workspace")
	}
	if !strings.Contains(err.Error(), "already exists") {
		t.Errorf("err = %v", err)
	}
}

func TestCreateReportsAnUnwritableStateDirectoryAsInfra(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes anywhere")
	}
	state := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(state, 0o555); err != nil {
		t.Fatal(err)
	}
	_, err := Create(state, "run-1")
	if err == nil {
		t.Fatal("a read-only state directory was accepted")
	}
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassInfra {
		t.Errorf("class = %v, want infra: the machine is misconfigured, not the user's flags", c)
	}
}
