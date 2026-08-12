// Package workspace owns a run's identity and the one directory everything it produces lives under.
//
// Spec §10 requires both together: a unique run_id AND an isolated workspace holding the cluster
// directory, the evidence and failures.jsonl. The pairing is what makes two runs on one machine
// distinguishable after the fact -- without it, the second run's failures.jsonl appends to the
// first's and a defect gets attributed to the wrong profile.
package workspace

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Workspace is one run's directory layout. Every field is absolute.
type Workspace struct {
	RunID    string
	Root     string // <state>/runs/<run_id>
	Cluster  string // the engine builds its chain here (passed as -o)
	Evidence string // node logs, tampered payloads, anything a human needs after a trip
	// Failures is where failures_lib.sh actually appends, which is inside the CLUSTER directory,
	// not beside it: gate.sh sets FAILURES_OUTDIR to the cluster outdir so a run's defect rows
	// travel with the node directories they refer to. This field mirrors the engine rather than
	// declaring a tidier path of its own -- a host that reported an evidence path nothing writes
	// to would send an operator to an empty file after a real trip.
	Failures string
}

// NewRunID returns a fresh identifier: a UTC timestamp for ordering, plus random bytes because a
// timestamp alone collides between two runs started in the same second, which is exactly what a CI
// matrix does.
//
// The character set is deliberately narrow -- digits, uppercase hex, one dash. The id becomes a
// path component and a JSON field, so anything that needs quoting or normalizing anywhere would
// have to be handled everywhere.
func NewRunID(now time.Time) (string, error) {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fbterr.Hostf("cannot generate a run id: %v", err)
	}
	return now.UTC().Format("20060102T150405Z") + "-" + strings.ToUpper(hex.EncodeToString(b[:])), nil
}

// ValidRunID reports whether s is safe to use as a path component and an identifier.
//
// This is not cosmetic. A run id reaches fbt from the outside -- `cluster down --run-id X` names a
// registry entry, and the id is joined onto the state directory to find its workspace. "../.." or
// an absolute path would make a cleanup command delete somewhere else entirely.
func ValidRunID(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

// Create makes the workspace for runID under stateDir and returns its layout.
//
// The run directory is created with os.Mkdir, not MkdirAll: an id that already exists must be an
// error, not a silent join. Two runs sharing one workspace would interleave their failures.jsonl
// rows and build two chains in one cluster directory -- and the second run would look like it had
// inherited the first one's defects.
func Create(stateDir, runID string) (Workspace, error) {
	w, err := Layout(stateDir, runID)
	if err != nil {
		return w, err
	}
	if err := os.MkdirAll(filepath.Dir(w.Root), 0o755); err != nil {
		return w, fbterr.Infraf("cannot create the run directory under %s: %v", stateDir, err)
	}
	if err := os.Mkdir(w.Root, 0o755); err != nil {
		if os.IsExist(err) {
			return w, fbterr.Hostf("workspace %s already exists; run ids must be unique", w.Root)
		}
		return w, fbterr.Infraf("cannot create workspace %s: %v", w.Root, err)
	}
	for _, d := range []string{w.Cluster, w.Evidence} {
		if err := os.Mkdir(d, 0o755); err != nil {
			return w, fbterr.Infraf("cannot create %s: %v", d, err)
		}
	}
	return w, nil
}

// Layout computes the paths without creating anything -- what `cluster down --run-id` needs to
// find an existing run, and what a dry run prints.
func Layout(stateDir, runID string) (Workspace, error) {
	if !ValidRunID(runID) {
		return Workspace{}, fbterr.Configf("%q is not a valid run id: only letters, digits, dash "+
			"and underscore, at most 64 characters", runID)
	}
	if stateDir == "" || !filepath.IsAbs(stateDir) {
		// A relative state directory would put the workspace somewhere that depends on the process
		// working directory, and the engine runs with a DIFFERENT working directory (spec §7.3).
		return Workspace{}, fbterr.Configf("the state directory must be an absolute path, got %q",
			stateDir)
	}
	root := filepath.Join(stateDir, "runs", runID)
	return Workspace{
		RunID:    runID,
		Root:     root,
		Cluster:  filepath.Join(root, "cluster"),
		Evidence: filepath.Join(root, "evidence"),
		Failures: filepath.Join(root, "cluster", "failures.jsonl"),
	}, nil
}
