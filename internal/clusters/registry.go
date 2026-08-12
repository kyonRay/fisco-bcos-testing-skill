// Package clusters is the registry of live FISCO-BCOS clusters on this machine, and the locking
// that keeps two runs from colliding in it.
//
// A workspace isolates FILES. It cannot isolate ports: build_chain's defaults put p2p on 30300,
// the BCOS RPC on 20200 and the web3 RPC on 8545 no matter which directory the chain is built in
// (spec §10). So the registry, not the workspace, is what makes concurrency safe -- and it lives
// in a FIXED state directory rather than inside a run's workspace, because a crashed run's
// leftovers have to be findable by the next run, which does not know the dead one's workspace path.
//
// Two levels of locking, doing different jobs:
//
//   - A short transaction lock (flock on one file) held only while the registry is read and
//     written. Without it, two fbt processes both see "no conflict" and both write an entry --
//     the classic check-then-act race, and the thing a JSON file per cluster cannot prevent on
//     its own.
//   - The entry itself, which is a PERSISTENT reservation. It outlives the `cluster up` process
//     that created it and stands until `cluster down` or stale reclamation. A lock released when
//     the creating command exits would reserve nothing at all: the chain it started is still
//     running and still holding the ports.
package clusters

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/workspace"
)

// Entry is one registered cluster. It is the persistent reservation.
type Entry struct {
	RunID     string      `json:"run_id"`
	Workspace string      `json:"workspace"`
	Profile   string      `json:"profile,omitempty"`
	Ports     []PortRange `json:"ports"`
	Nodes     []Node      `json:"nodes"`
	CreatedAt string      `json:"created_at"`

	// Status is computed from the node processes at read time, never stored: a status written to
	// disk is a claim about the past, and the whole point of the check is what is true now.
	Status Status `json:"status"`
}

// Registry is the directory of entries plus its transaction lock.
type Registry struct {
	Dir    string
	Prober Prober
	Now    func() time.Time
}

func New(dir string) *Registry {
	return &Registry{Dir: dir, Prober: OSProber{}, Now: time.Now}
}

func (r *Registry) prober() Prober {
	if r.Prober == nil {
		return OSProber{}
	}
	return r.Prober
}

func (r *Registry) now() time.Time {
	if r.Now == nil {
		return time.Now()
	}
	return r.Now()
}

const lockName = ".registry.lock"

// withLock runs fn while holding the exclusive transaction lock.
//
// flock is released by the kernel when the process dies, which is what makes it safe here: an fbt
// that crashes mid-transaction must not leave a lock nobody can clear. That is also why this lock
// is NOT the reservation -- a reservation has to survive the process that made it.
func (r *Registry) withLock(fn func() error) error {
	if err := os.MkdirAll(r.Dir, 0o755); err != nil {
		return fbterr.Infraf("cannot create the cluster registry at %s: %v", r.Dir, err)
	}
	f, err := os.OpenFile(filepath.Join(r.Dir, lockName), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fbterr.Infraf("cannot open the registry lock: %v", err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return fbterr.Infraf("cannot lock the cluster registry: %v", err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}

// List returns every entry with its status computed now, sorted by run id.
func (r *Registry) List() ([]Entry, error) {
	var out []Entry
	err := r.withLock(func() error {
		var err error
		out, err = r.listLocked()
		return err
	})
	return out, err
}

func (r *Registry) listLocked() ([]Entry, error) {
	names, err := filepath.Glob(filepath.Join(r.Dir, "*.json"))
	if err != nil {
		return nil, fbterr.Infraf("cannot read the cluster registry: %v", err)
	}
	sort.Strings(names)
	out := make([]Entry, 0, len(names))
	for _, n := range names {
		e, err := readEntry(n)
		if err != nil {
			return nil, err
		}
		e.Status = statusOf(e.Nodes, r.prober())
		out = append(out, e)
	}
	return out, nil
}

func readEntry(path string) (Entry, error) {
	var e Entry
	b, err := os.ReadFile(path)
	if err != nil {
		return e, fbterr.Infraf("cannot read registry entry %s: %v", path, err)
	}
	if err := json.Unmarshal(b, &e); err != nil {
		// A corrupt entry is fbt's own doing: nothing else writes this directory.
		return e, fbterr.Hostf("registry entry %s is not valid JSON: %v", path, err)
	}
	if e.RunID == "" {
		return e, fbterr.Hostf("registry entry %s names no run", path)
	}
	return e, nil
}

func (r *Registry) path(runID string) string {
	return filepath.Join(r.Dir, runID+".json")
}

// Reclaim removes every entry whose processes are all gone and reports what it removed.
//
// It runs at startup (spec §10). Without it a single crashed run holds its ports forever, and the
// next run on that machine is refused with no way to see why -- the operator would have to know
// this directory exists.
func (r *Registry) Reclaim() ([]Entry, error) {
	var removed []Entry
	err := r.withLock(func() error {
		entries, err := r.listLocked()
		if err != nil {
			return err
		}
		for _, e := range entries {
			if e.Status != StatusStale {
				continue
			}
			if err := os.Remove(r.path(e.RunID)); err != nil && !os.IsNotExist(err) {
				return fbterr.Infraf("cannot reclaim stale entry %s: %v", e.RunID, err)
			}
			removed = append(removed, e)
		}
		return nil
	})
	return removed, err
}

// Reserve records a new cluster, refusing anything that would collide with a live one.
//
// The conflict check and the write happen inside ONE lock hold. Splitting them is the whole bug
// this design exists to prevent: two fbt processes starting together both find the registry empty,
// both conclude they may proceed, and both build a chain on port 30300.
func (r *Registry) Reserve(e Entry, allowParallel bool) (Entry, error) {
	if !workspace.ValidRunID(e.RunID) {
		return e, fbterr.Configf("%q is not a valid run id", e.RunID)
	}
	if len(e.Ports) == 0 {
		return e, fbterr.Hostf("a reservation with no port ranges reserves nothing")
	}
	e.CreatedAt = r.now().UTC().Format(time.RFC3339)
	e.Status = ""

	err := r.withLock(func() error {
		existing, err := r.listLocked()
		if err != nil {
			return err
		}
		var live []Entry
		for _, x := range existing {
			if x.RunID == e.RunID {
				return fbterr.Hostf("run %s is already registered", e.RunID)
			}
			if x.Status.Live() {
				live = append(live, x)
			}
		}
		if len(live) > 0 {
			if !allowParallel {
				// The default is a single instance, because the ports are fixed and the failure
				// mode of getting this wrong -- two chains on one port range -- produces symptoms
				// that look like consensus bugs.
				return fbterr.Configf("cluster %s is still active (%s); stop it with "+
					"`fbt cluster down --run-id %s`, or pass --allow-parallel with non-overlapping "+
					"port bases", live[0].RunID, live[0].Status, live[0].RunID)
			}
			// --allow-parallel is permission to try, not permission to overlap.
			for _, x := range live {
				if c := Conflicts(e.Ports, x.Ports); len(c) > 0 {
					return fbterr.Configf("--allow-parallel needs disjoint ports, but this run "+
						"collides with %s: %s", x.RunID, describeConflicts(c))
				}
			}
		}
		return r.writeLocked(e)
	})
	return e, err
}

// Update replaces an entry, typically to record the node PIDs once the chain is up.
func (r *Registry) Update(e Entry) error {
	e.Status = ""
	return r.withLock(func() error {
		if _, err := os.Stat(r.path(e.RunID)); err != nil {
			return fbterr.Hostf("run %s is not registered, so there is nothing to update", e.RunID)
		}
		return r.writeLocked(e)
	})
}

// writeLocked writes one entry atomically. The temp file is created in the SAME directory so the
// rename cannot cross a filesystem boundary -- a rename that degrades into copy-then-delete is not
// atomic, and a reader would then be able to see a half-written entry.
func (r *Registry) writeLocked(e Entry) error {
	b, err := json.MarshalIndent(e, "", "  ")
	if err != nil {
		return fbterr.Hostf("cannot encode registry entry %s: %v", e.RunID, err)
	}
	tmp, err := os.CreateTemp(r.Dir, "."+e.RunID+".*.tmp")
	if err != nil {
		return fbterr.Infraf("cannot write the registry entry: %v", err)
	}
	name := tmp.Name()
	defer os.Remove(name) // a no-op once the rename has succeeded
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return fbterr.Infraf("cannot write the registry entry: %v", err)
	}
	if err := tmp.Close(); err != nil {
		return fbterr.Infraf("cannot write the registry entry: %v", err)
	}
	if err := os.Rename(name, r.path(e.RunID)); err != nil {
		return fbterr.Infraf("cannot install the registry entry: %v", err)
	}
	return nil
}

// Release removes one entry: the reservation is over.
func (r *Registry) Release(runID string) error {
	if !workspace.ValidRunID(runID) {
		return fbterr.Configf("%q is not a valid run id", runID)
	}
	return r.withLock(func() error {
		if err := os.Remove(r.path(runID)); err != nil {
			if os.IsNotExist(err) {
				return fbterr.Configf("no cluster is registered under run id %s", runID)
			}
			return fbterr.Infraf("cannot release %s: %v", runID, err)
		}
		return nil
	})
}

// Resolve finds the single cluster a command should act on.
//
// Spec §10: with no target given and several clusters active, fbt does not guess -- it returns a
// configuration error naming the candidates. Guessing here means tearing down the wrong chain,
// which on a shared test machine destroys somebody else's investigation.
func (r *Registry) Resolve(runID, workspacePath string) (Entry, error) {
	entries, err := r.List()
	if err != nil {
		return Entry{}, err
	}
	switch {
	case runID != "":
		for _, e := range entries {
			if e.RunID == runID {
				return e, nil
			}
		}
		return Entry{}, fbterr.Configf("no cluster is registered under run id %s", runID)
	case workspacePath != "":
		want := filepath.Clean(workspacePath)
		for _, e := range entries {
			if filepath.Clean(e.Workspace) == want {
				return e, nil
			}
		}
		return Entry{}, fbterr.Configf("no cluster is registered for workspace %s", workspacePath)
	}

	var live []Entry
	for _, e := range entries {
		if e.Status.Live() {
			live = append(live, e)
		}
	}
	switch len(live) {
	case 0:
		return Entry{}, fbterr.Configf("no cluster is active")
	case 1:
		return live[0], nil
	default:
		ids := make([]string, 0, len(live))
		for _, e := range live {
			ids = append(ids, e.RunID)
		}
		return Entry{}, fbterr.Configf("%d clusters are active (%s); name one with --run-id or "+
			"--workspace", len(live), strings.Join(ids, ", "))
	}
}
