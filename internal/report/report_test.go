package report

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// The real envelope: everything but ev/ts/seq/run_id/source lives under "payload". Writing these
// fixtures flat made the parser look correct while reading nothing -- the test passed against a
// parser that could not read a single actual event.
const transcript = `{"schema_version":"1.0.0","ev":"run_started","run_id":"RUN1","seq":1,"ts":"2026-08-19T09:26:43Z","source":"host","payload":{"command":"gate","profile":"production-enterprise"}}
{"schema_version":"1.0.0","ev":"scenario_finished","seq":2,"source":"engine","payload":{"name":"dual_rpc","result":"pass"}}
{"schema_version":"1.0.0","ev":"oracle_check","seq":3,"source":"engine","payload":{"oracle":"crash","phase":"after:dual_rpc","verdict":"ok"}}
{"schema_version":"1.0.0","ev":"oracle_check","seq":4,"source":"engine","payload":{"oracle":"halt","phase":"after:dual_rpc","verdict":"trip"}}
{"schema_version":"1.0.0","ev":"case_replayed","seq":5,"source":"engine","payload":{"file":"fuzz_seed43_idx11.case","result":"fail"}}
{"schema_version":"1.0.0","ev":"run_finished","seq":6,"ts":"2026-08-19T09:31:02Z","source":"host","payload":{"exit":10}}
`

const defects = `{"profile":"production-enterprise.profile","scenario":"case:fuzz_seed43_idx11.case","oracle":"crash","severity":"高","desc":"oracle_crash tripped","repro":"bash run_case.sh x","evidence":"/ws/cluster/127.0.0.1","version":"unknown","reported":false,"ts":"2026-08-19T09:27:33Z"}
{"profile":"p","scenario":"s","oracle":"halt","severity":"高","desc":"d","repro":"r","evidence":"e","version":"v","reported":true,"record_id":"REC1","ts":"t"}
`

func TestLoadBuildsTheMatrixAndCountsWhatIsUnreported(t *testing.T) {
	dir := t.TempDir()
	ev := write(t, dir, "events.jsonl", transcript)
	fa := write(t, dir, "failures.jsonl", defects)

	r, err := Load("RUN1", dir, ev, fa)
	if err != nil {
		t.Fatal(err)
	}
	if r.Command != "gate" || r.Profile != "production-enterprise" || r.Exit != 10 {
		t.Errorf("header = %+v", r)
	}
	if len(r.Matrix) != 4 {
		t.Fatalf("matrix has %d cells, want 4: %+v", len(r.Matrix), r.Matrix)
	}
	// The report must not re-judge anything: exit 10 comes from the transcript, not from counting
	// the trips. A second source of truth here is how a summary comes to disagree with its run.
	if r.Exit != 10 {
		t.Errorf("exit = %d; it must be the one the run recorded", r.Exit)
	}
	// Two defects, one already pushed. The unreported count is what decides whether there is still
	// work to do after reading, so it counts rows rather than defects.
	if len(r.Defects) != 2 || r.Unreported != 1 {
		t.Errorf("defects = %d, unreported = %d; want 2 and 1", len(r.Defects), r.Unreported)
	}
	if r.Partial {
		t.Error("a transcript with run_finished is not partial")
	}
}

// A killed run has no terminator. Rendering its truncated matrix as though it were complete is the
// one thing a report must not do -- it would read as "these stages are all that ran".
func TestATranscriptWithNoTerminatorIsMarkedPartial(t *testing.T) {
	dir := t.TempDir()
	ev := write(t, dir, "events.jsonl",
		`{"ev":"run_started","ts":"t","payload":{}}`+"\n"+
			`{"ev":"scenario_finished","payload":{"name":"ut","result":"pass"}}`+"\n")

	r, err := Load("RUN2", dir, ev, filepath.Join(dir, "absent.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !r.Partial {
		t.Error("a transcript with no run_finished must be reported as incomplete")
	}
}

// A transcript truncated mid-write by a kill is exactly when the surviving lines matter most.
func TestOneUnreadableLineDoesNotDiscardTheRest(t *testing.T) {
	dir := t.TempDir()
	ev := write(t, dir, "events.jsonl",
		`{"ev":"scenario_finished","payload":{"name":"ut","result":"pass"}}`+"\n"+
			`{"ev":"scenario_finished","payload":{"name":"dual_r`+"\n") // killed mid-write

	r, err := Load("RUN3", dir, ev, filepath.Join(dir, "absent.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Matrix) != 1 || r.Matrix[0].Stage != "ut" {
		t.Errorf("matrix = %+v; the complete line must survive the broken one", r.Matrix)
	}
}

// A dry run, or a command that failed before its workspace existed, has no transcript. That is a
// real answer -- "nothing was recorded" -- not an error to refuse on.
func TestAnAbsentTranscriptIsEmptyNotAnError(t *testing.T) {
	dir := t.TempDir()
	r, err := Load("RUN4", dir, filepath.Join(dir, "none.jsonl"), filepath.Join(dir, "none2.jsonl"))
	if err != nil {
		t.Fatalf("an absent transcript errored: %v", err)
	}
	if len(r.Matrix) != 0 || r.Partial {
		t.Errorf("r = %+v; an absent transcript is empty and not partial", r)
	}
}

// Run ids begin with a sortable UTC timestamp, so reverse lexical order IS newest-first. `fbt
// report` with no --run-id picks ids[0], and getting this backwards would silently report on the
// oldest run on the machine.
func TestRunsAreListedNewestFirst(t *testing.T) {
	dir := t.TempDir()
	for _, id := range []string{"20260819T085744Z-AAA", "20260819T092643Z-BBB", "20260812T074302Z-CCC"} {
		if err := os.Mkdir(filepath.Join(dir, id), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	got, err := Runs(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0] != "20260819T092643Z-BBB" || got[2] != "20260812T074302Z-CCC" {
		t.Errorf("Runs = %v, want newest first", got)
	}
}

// Run ids carry a one-second timestamp, so two runs started in the same second sort by their
// random suffix -- no order at all. Back-to-back rounds land in the same second routinely, and
// `fbt report` with no --run-id would then pick whichever suffix sorted higher.
func TestSameSecondRunsAreOrderedByWhenTheyWereWritten(t *testing.T) {
	dir := t.TempDir()
	older := filepath.Join(dir, "20260819T092643Z-FFFF")
	newer := filepath.Join(dir, "20260819T092643Z-0001") // sorts HIGHER lexically, but is newer
	for _, d := range []string{older, newer} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-time.Hour)
	if err := os.Chtimes(older, past, past); err != nil {
		t.Fatal(err)
	}
	got, err := Runs(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got[0] != filepath.Base(newer) {
		t.Errorf("newest = %s, want %s: a lexical sort picks the random suffix, not the time",
			got[0], filepath.Base(newer))
	}
}
