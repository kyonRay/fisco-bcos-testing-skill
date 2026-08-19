// Package report turns a finished run's transcript into the account a human reads afterwards.
//
// It reads only what is on disk -- <workspace>/events.jsonl and the engine's failures.jsonl -- and
// never re-runs anything. That separation is the point: the report is a VIEW of the run, so it
// cannot disagree with the verdict the run already returned. A reporter that recomputed anything
// would be a second source of truth, and the two would drift.
package report

import (
	"bufio"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Cell is one square of the evidence matrix: what ran, in which phase, and how it came out.
type Cell struct {
	Stage  string `json:"stage"`            // scenario or case name
	Kind   string `json:"kind"`             // scenario | case | oracle
	Phase  string `json:"phase,omitempty"`  // for oracles: baseline, after:<scenario>
	Result string `json:"result"`           // pass | fail | trip | skip
	Reason string `json:"reason,omitempty"` // why it was skipped
}

// Defect is one row of the engine's failures.jsonl, as written by failures_append.
type Defect struct {
	Profile  string `json:"profile"`
	Scenario string `json:"scenario"`
	Oracle   string `json:"oracle"`
	Severity string `json:"severity"`
	Desc     string `json:"desc"`
	Repro    string `json:"repro"`
	Evidence string `json:"evidence"`
	Version  string `json:"version"`
	Reported bool   `json:"reported"`
	RecordID string `json:"record_id,omitempty"`
	TS       string `json:"ts"`
}

// Report is the whole account of one run.
type Report struct {
	RunID     string   `json:"run_id"`
	Workspace string   `json:"workspace"`
	Command   string   `json:"command,omitempty"`
	Profile   string   `json:"profile,omitempty"`
	Started   string   `json:"started,omitempty"`
	Finished  string   `json:"finished,omitempty"`
	Exit      int      `json:"exit"`
	Matrix    []Cell   `json:"matrix"`
	Defects   []Defect `json:"defects"`
	// Unreported counts the defects nobody has pushed anywhere. It is on the summary line because
	// it is the number that decides whether there is still work to do after reading.
	Unreported int `json:"unreported"`
	// Partial marks a run whose transcript has no terminator: the process was killed, or the
	// machine went down. Saying so beats presenting a truncated matrix as a complete one.
	Partial bool `json:"partial"`
}

// event is the subset of the normalized envelope a report needs. Every field an event carries
// beyond the envelope lives under "payload" -- the Normalizer nests them there, host events and
// engine events alike -- so reading the top level finds nothing but ev/ts/seq/run_id.
type event struct {
	Ev      string
	TS      string
	payload map[string]interface{}
}

func (e event) str(k string) string {
	if v, ok := e.payload[k].(string); ok {
		return v
	}
	return ""
}

func (e event) num(k string) int {
	switch v := e.payload[k].(type) {
	case float64:
		return int(v)
	case json.Number:
		if n, err := v.Int64(); err == nil {
			return int(n)
		}
	}
	return 0
}

// Load builds a report from one run's workspace.
func Load(runID, workspaceRoot, eventsPath, failuresPath string) (Report, error) {
	r := Report{RunID: runID, Workspace: workspaceRoot}
	evs, err := readEvents(eventsPath)
	if err != nil {
		return r, err
	}
	sawFinish := false
	for _, e := range evs {
		switch e.Ev {
		case "run_started":
			r.Started = e.TS
			r.Command = e.str("command")
			r.Profile = e.str("profile")
		case "run_finished":
			r.Finished = e.TS
			r.Exit = e.num("exit")
			sawFinish = true
		case "scenario_finished":
			r.Matrix = append(r.Matrix, Cell{
				Stage: e.str("name"), Kind: "scenario",
				Result: e.str("result"), Reason: e.str("skip_reason"),
			})
		case "case_replayed":
			r.Matrix = append(r.Matrix, Cell{
				Stage: e.str("file"), Kind: "case",
				Result: e.str("result"), Reason: e.str("skip_reason"),
			})
		case "oracle_check":
			r.Matrix = append(r.Matrix, Cell{
				Stage: e.str("oracle"), Kind: "oracle",
				Phase: e.str("phase"), Result: e.str("verdict"),
			})
		}
	}
	r.Partial = len(evs) > 0 && !sawFinish

	r.Defects, err = readDefects(failuresPath)
	if err != nil {
		return r, err
	}
	for _, d := range r.Defects {
		if !d.Reported {
			r.Unreported++
		}
	}
	return r, nil
}

func readEvents(path string) ([]event, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			// A run that never began one -- a dry run, or a command that failed before the
			// workspace existed. An empty transcript is a real answer, not an error.
			return nil, nil
		}
		return nil, fbterr.Infraf("cannot read the run transcript %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()

	var out []event
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var raw map[string]interface{}
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			// One unreadable line does not invalidate the rest. A transcript truncated mid-write by
			// a kill is exactly the case where the surviving lines matter most.
			continue
		}
		e := event{}
		e.Ev, _ = raw["ev"].(string)
		e.TS, _ = raw["ts"].(string)
		e.payload, _ = raw["payload"].(map[string]interface{})
		out = append(out, e)
	}
	return out, nil
}

func readDefects(path string) ([]Defect, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // no trips, so failures_append never created it
		}
		return nil, fbterr.Infraf("cannot read %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()

	var out []Defect
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var d Defect
		if err := json.Unmarshal([]byte(line), &d); err != nil {
			continue
		}
		out = append(out, d)
	}
	return out, nil
}

// Runs lists the run ids under a state directory, newest first.
//
// A run id is a UTC timestamp plus random bytes, and the timestamp has ONE-SECOND resolution --
// so two runs started in the same second sort by their random suffix, which is no order at all.
// That is not a corner case: back-to-back rounds land in the same second routinely, and `fbt
// report` with no --run-id would then pick whichever id happened to sort higher. The timestamp
// prefix decides first; within one second, the directory's modification time breaks the tie.
func Runs(stateDir string) ([]string, error) {
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fbterr.Infraf("cannot list runs under %s: %v", stateDir, err)
	}
	type run struct {
		id    string
		stamp string
		mod   time.Time
	}
	var runs []run
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		r := run{id: e.Name(), stamp: e.Name()}
		if i := strings.IndexByte(r.id, '-'); i > 0 {
			r.stamp = r.id[:i]
		}
		if info, err := e.Info(); err == nil {
			r.mod = info.ModTime()
		}
		runs = append(runs, r)
	}
	sort.Slice(runs, func(i, j int) bool {
		if runs[i].stamp != runs[j].stamp {
			return runs[i].stamp > runs[j].stamp
		}
		if !runs[i].mod.Equal(runs[j].mod) {
			return runs[i].mod.After(runs[j].mod)
		}
		return runs[i].id > runs[j].id
	})
	out := make([]string, 0, len(runs))
	for _, r := range runs {
		out = append(out, r.id)
	}
	return out, nil
}
