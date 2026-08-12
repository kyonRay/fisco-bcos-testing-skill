package clusters

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// fakeProber drives liveness without spawning processes: the tests need a cluster to be stale,
// degraded or alive on demand, which real PIDs cannot be made to do reliably.
type fakeProber struct {
	alive map[int]bool
	fp    map[int]string
}

func (f fakeProber) Alive(n Node) bool {
	if !f.alive[n.PID] {
		return false
	}
	// A registered fingerprint that no longer matches means the PID was reused by an unrelated
	// process: the cluster is gone even though the number is in use.
	if n.Start != "" && f.fp[n.PID] != "" && f.fp[n.PID] != n.Start {
		return false
	}
	return true
}
func (f fakeProber) Fingerprint(pid int) string { return f.fp[pid] }

func reg(t *testing.T, p Prober) *Registry {
	t.Helper()
	r := New(filepath.Join(t.TempDir(), "clusters"))
	r.Prober = p
	r.Now = func() time.Time { return time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC) }
	return r
}

func entry(runID string, p2p int, nodes ...Node) Entry {
	ports, err := DerivePorts(len(nodes)+1, p2p, p2p+10000, p2p+20000)
	if err != nil {
		panic(err)
	}
	return Entry{RunID: runID, Workspace: "/ws/" + runID, Ports: ports, Nodes: nodes}
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

// The node count walks upward from the base, so a legal base can still put the last node past the
// end of the port space. Unchecked, the chain simply fails to bind and the symptom is "the cluster
// will not come up" with no cause attached.
func TestAPortRangeMayNotRunPastTheEndOfThePortSpace(t *testing.T) {
	if _, err := DerivePorts(10, 65530, 20200, 8545); err == nil {
		t.Fatal("65530 + 10 nodes was accepted")
	}
	if _, err := DerivePorts(6, 65530, 20200, 8545); err != nil {
		t.Fatalf("65530 + 6 nodes ends exactly at 65535 and must be legal: %v", err)
	}
}

// Comparing only like-for-like ranges is the mistake that lets a default rpc base of 20200 sit
// inside somebody else's p2p span.
func TestOverlapIsCheckedAcrossDIFFERENTRangeNames(t *testing.T) {
	a := []PortRange{{Name: "p2p", Base: 20195, Count: 10}} // 20195-20204
	b := []PortRange{{Name: "rpc", Base: 20200, Count: 4}}  // 20200-20203
	if c := Conflicts(a, b); len(c) == 0 {
		t.Fatal("a p2p range overlapping an rpc range was reported as disjoint")
	}
	if c := Conflicts(a, []PortRange{{Name: "rpc", Base: 20205, Count: 4}}); len(c) != 0 {
		t.Errorf("adjacent-but-disjoint ranges were reported as conflicting: %v", c)
	}
}

func TestAClustersOwnRangesMustNotOverlap(t *testing.T) {
	if _, err := DerivePorts(4, 30300, 30301, 8545); err == nil {
		t.Fatal("a profile that put rpc inside the p2p span was accepted")
	}
}

// ---------------------------------------------------------------------------
// Reservation and conflicts
// ---------------------------------------------------------------------------

func TestASecondClusterIsRefusedWhileOneIsActive(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}}
	r := reg(t, p)
	if _, err := r.Reserve(entry("run-a", 30300, Node{Name: "node0", PID: 100}), false); err != nil {
		t.Fatal(err)
	}
	_, err := r.Reserve(entry("run-b", 40300, Node{Name: "node0", PID: 200}), false)
	if err == nil {
		t.Fatal("a second cluster was allowed with no --allow-parallel")
	}
	if !strings.Contains(err.Error(), "run-a") || !strings.Contains(err.Error(), "cluster down") {
		t.Errorf("err = %v; it must name the blocking run and how to clear it", err)
	}
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassConfig {
		t.Errorf("class = %v, want config", c)
	}
}

// --allow-parallel is permission to TRY, not permission to overlap.
func TestAllowParallelStillRefusesOverlappingPorts(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}}
	r := reg(t, p)
	if _, err := r.Reserve(entry("run-a", 30300, Node{Name: "node0", PID: 100}), false); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Reserve(entry("run-b", 30301, Node{Name: "node0", PID: 200}), true); err == nil {
		t.Fatal("--allow-parallel waved through an overlapping port range")
	}
	if _, err := r.Reserve(entry("run-c", 41000, Node{Name: "node0", PID: 300}), true); err != nil {
		t.Fatalf("disjoint ranges must be allowed under --allow-parallel: %v", err)
	}
}

// The check and the write must happen inside one lock hold. Two processes that both read an empty
// registry and both write would both build a chain on port 30300.
func TestConcurrentReservationsProduceExactlyOneWinner(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true, 200: true, 300: true, 400: true}}
	r := reg(t, p)
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins := 0
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := r.Reserve(entry(fmt.Sprintf("run-%d", i), 30300+i*1000,
				Node{Name: "node0", PID: 100 * (i + 1)}), false)
			if err == nil {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if wins != 1 {
		t.Errorf("%d reservations succeeded, want exactly 1", wins)
	}
}

// The real race is two separate `fbt gate run` invocations, so the lock has to be one the KERNEL
// enforces, not a mutex inside one process. flock keys on the open file description, which is why
// the two independent opens below block each other exactly as two processes would -- and why a
// sync.Mutex here would pass every other test in this file while protecting nothing.
func TestTheLockBlocksASecondIndependentHolder(t *testing.T) {
	r := reg(t, fakeProber{alive: map[int]bool{}})
	if err := os.MkdirAll(r.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Hold the lock in this process while a helper tries to take it, and prove the helper waited.
	held := make(chan struct{})
	release := make(chan struct{})
	go func() {
		_ = r.withLock(func() error {
			close(held)
			<-release
			return nil
		})
	}()
	<-held

	done := make(chan time.Duration, 1)
	go func() {
		start := time.Now()
		other := New(r.Dir)
		other.Prober = fakeProber{alive: map[int]bool{}}
		_, _ = other.List()
		done <- time.Since(start)
	}()
	select {
	case d := <-done:
		t.Fatalf("a second holder took the lock after %v while it was still held", d)
	case <-time.After(300 * time.Millisecond):
	}
	close(release)
	if d := <-done; d < 250*time.Millisecond {
		t.Errorf("the waiter returned after %v; it cannot have waited for the lock", d)
	}
}

// ---------------------------------------------------------------------------
// Stale reclamation and PID reuse
// ---------------------------------------------------------------------------

// One crashed run must not hold the machine's ports forever.
func TestAllNodesGoneIsStaleAndIsReclaimed(t *testing.T) {
	p := fakeProber{alive: map[int]bool{}}
	r := reg(t, p)
	if _, err := r.Reserve(entry("dead", 30300, Node{Name: "node0", PID: 100}), false); err != nil {
		t.Fatal(err)
	}
	removed, err := r.Reclaim()
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 1 || removed[0].RunID != "dead" {
		t.Fatalf("reclaimed %v, want the dead entry", removed)
	}
	// ...and the ports are free again.
	if _, err := r.Reserve(entry("fresh", 30300, Node{Name: "node0", PID: 999}), false); err != nil {
		t.Errorf("the reclaimed ports are still blocked: %v", err)
	}
}

// SOME nodes alive is neither healthy nor free. Reclaiming it would hand the survivors' ports to a
// new run, and it is also exactly the state a consensus-halt investigation wants left intact.
func TestAPartiallyDeadClusterIsDegradedAndNotReclaimed(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}}
	r := reg(t, p)
	if _, err := r.Reserve(entry("half", 30300,
		Node{Name: "node0", PID: 100}, Node{Name: "node1", PID: 101}), false); err != nil {
		t.Fatal(err)
	}
	list, err := r.List()
	if err != nil {
		t.Fatal(err)
	}
	if list[0].Status != StatusDegraded {
		t.Fatalf("status = %s, want degraded", list[0].Status)
	}
	removed, err := r.Reclaim()
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 0 {
		t.Errorf("a degraded cluster was reclaimed; its surviving nodes still hold their ports")
	}
	if !list[0].Status.Live() {
		t.Error("a degraded cluster must still block a colliding reservation")
	}
}

// A reused PID makes a dead cluster look alive, and fbt would then refuse to run forever.
func TestAReusedPIDDoesNotKeepADeadClusterAlive(t *testing.T) {
	p := fakeProber{
		alive: map[int]bool{100: true},                 // the number is in use...
		fp:    map[int]string{100: "Wed Aug 13 09:00"}, // ...by a process started later
	}
	r := reg(t, p)
	if _, err := r.Reserve(entry("old", 30300,
		Node{Name: "node0", PID: 100, Start: "Tue Aug 12 08:00"}), false); err != nil {
		t.Fatal(err)
	}
	list, _ := r.List()
	if list[0].Status != StatusStale {
		t.Fatalf("status = %s, want stale: the PID belongs to a different process now", list[0].Status)
	}
}

// The opposite mistake is worse: treating a LIVE cluster as stale reclaims its ports, and two
// chains then fight over 30300 with symptoms that look like consensus bugs.
func TestAMatchingFingerprintKeepsAClusterAlive(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}, fp: map[int]string{100: "Tue Aug 12 08:00"}}
	r := reg(t, p)
	if _, err := r.Reserve(entry("live", 30300,
		Node{Name: "node0", PID: 100, Start: "Tue Aug 12 08:00"}), false); err != nil {
		t.Fatal(err)
	}
	list, _ := r.List()
	if list[0].Status != StatusActive {
		t.Fatalf("status = %s, want active", list[0].Status)
	}
}

// An entry recorded before its processes started registers no PIDs. Calling that "free" is the
// assumption that reclaims a cluster which is in the middle of coming up.
func TestAnEntryWithNoNodesIsNotTreatedAsFree(t *testing.T) {
	r := reg(t, fakeProber{alive: map[int]bool{}})
	if _, err := r.Reserve(entry("starting", 30300), false); err != nil {
		t.Fatal(err)
	}
	list, _ := r.List()
	if list[0].Status != StatusUnknown || !list[0].Status.Live() {
		t.Errorf("status = %s live=%v, want unknown and still holding",
			list[0].Status, list[0].Status.Live())
	}
	if removed, _ := r.Reclaim(); len(removed) != 0 {
		t.Error("a cluster that had not registered its PIDs yet was reclaimed")
	}
}

// ---------------------------------------------------------------------------
// Resolve: fbt must not guess which chain to tear down
// ---------------------------------------------------------------------------

func TestResolveRefusesToGuessBetweenSeveralActiveClusters(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true, 200: true}}
	r := reg(t, p)
	mustReserve(t, r, entry("run-a", 30300, Node{Name: "n", PID: 100}), true)
	mustReserve(t, r, entry("run-b", 41000, Node{Name: "n", PID: 200}), true)

	_, err := r.Resolve("", "")
	if err == nil {
		t.Fatal("fbt picked one of two active clusters on its own")
	}
	if !strings.Contains(err.Error(), "run-a") || !strings.Contains(err.Error(), "run-b") {
		t.Errorf("err = %v; it must list the candidates", err)
	}
	if e, err := r.Resolve("run-b", ""); err != nil || e.RunID != "run-b" {
		t.Errorf("naming a run id must resolve it: %v %v", e.RunID, err)
	}
	if e, err := r.Resolve("", "/ws/run-a"); err != nil || e.RunID != "run-a" {
		t.Errorf("naming a workspace must resolve it: %v %v", e.RunID, err)
	}
}

func TestResolvePicksTheOnlyActiveClusterWithoutAFlag(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}}
	r := reg(t, p)
	mustReserve(t, r, entry("only", 30300, Node{Name: "n", PID: 100}), false)
	e, err := r.Resolve("", "")
	if err != nil || e.RunID != "only" {
		t.Errorf("got %q, %v", e.RunID, err)
	}
}

// A stale entry is not a target: `cluster down` on it would try to stop processes that are gone.
func TestResolveIgnoresStaleEntriesWhenNoTargetIsNamed(t *testing.T) {
	r := reg(t, fakeProber{alive: map[int]bool{}})
	mustReserve(t, r, entry("dead", 30300, Node{Name: "n", PID: 100}), false)
	if _, err := r.Resolve("", ""); err == nil || !strings.Contains(err.Error(), "no cluster is active") {
		t.Errorf("err = %v, want 'no cluster is active'", err)
	}
}

// ---------------------------------------------------------------------------
// Storage integrity
// ---------------------------------------------------------------------------

func TestEntriesSurviveAReopenAndStatusIsNeverStored(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}}
	r := reg(t, p)
	mustReserve(t, r, entry("keep", 30300, Node{Name: "node0", PID: 100}), false)

	raw, err := os.ReadFile(filepath.Join(r.Dir, "keep.json"))
	if err != nil {
		t.Fatal(err)
	}
	// A status on disk is a claim about the past, and the whole point of the check is what is true
	// NOW. A stored "active" would survive the reboot that killed the chain.
	if strings.Contains(string(raw), `"status": "active"`) {
		t.Errorf("status was written to disk:\n%s", raw)
	}

	other := New(r.Dir)
	other.Prober = fakeProber{alive: map[int]bool{}}
	list, err := other.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].Status != StatusStale {
		t.Errorf("a fresh reader must recompute status from the live processes, got %v", list)
	}
}

func TestReleaseFreesThePortsAndReportsAnUnknownRun(t *testing.T) {
	p := fakeProber{alive: map[int]bool{100: true}}
	r := reg(t, p)
	mustReserve(t, r, entry("gone", 30300, Node{Name: "n", PID: 100}), false)
	if err := r.Release("gone"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Reserve(entry("next", 30300, Node{Name: "n", PID: 100}), false); err != nil {
		t.Errorf("the released ports are still blocked: %v", err)
	}
	if err := r.Release("never-existed"); err == nil {
		t.Error("releasing an unknown run reported success")
	}
	// A run id is joined onto a directory path; a traversal must never reach the filesystem.
	if err := r.Release("../../etc"); err == nil {
		t.Error("a traversal run id was accepted")
	}
}

func TestACorruptEntryIsAHostError(t *testing.T) {
	r := reg(t, fakeProber{alive: map[int]bool{}})
	if err := os.MkdirAll(r.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.Dir, "bad.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := r.List()
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassHost {
		t.Errorf("class = %v (err %v); nothing but fbt writes this directory", c, err)
	}
}

func mustReserve(t *testing.T, r *Registry, e Entry, parallel bool) {
	t.Helper()
	if _, err := r.Reserve(e, parallel); err != nil {
		t.Fatalf("reserve %s: %v", e.RunID, err)
	}
}

// ---------------------------------------------------------------------------
// The REAL prober. Everything above runs on a fake, so without these the shipped
// implementation would be entirely unexercised.
// ---------------------------------------------------------------------------

func TestTheRealProberRecognisesThisProcess(t *testing.T) {
	me := os.Getpid()
	fp := OSProber{}.Fingerprint(me)
	if fp == "" {
		t.Skip("ps is unavailable; the fingerprint falls back to the PID alone by design")
	}
	if !(OSProber{}).Alive(Node{PID: me, Start: fp}) {
		t.Error("the test process was reported dead")
	}
	// The same PID with a fingerprint from another moment is a REUSED pid, not our process.
	if (OSProber{}).Alive(Node{PID: me, Start: "Mon Jan  1 00:00:00 1990"}) {
		t.Error("a stale fingerprint was accepted; PID reuse would go undetected")
	}
}

func TestTheRealProberReportsAnExitedProcessDead(t *testing.T) {
	cmd := exec.Command("/usr/bin/true")
	if err := cmd.Start(); err != nil {
		t.Skip(err)
	}
	pid := cmd.Process.Pid
	_ = cmd.Wait()
	if (OSProber{}).Alive(Node{PID: pid, Start: "whatever"}) {
		t.Errorf("pid %d exited and was reaped but is still reported alive", pid)
	}
	if (OSProber{}).Alive(Node{PID: 0}) || (OSProber{}).Alive(Node{PID: -1}) {
		t.Error("a nonsensical pid was reported alive")
	}
}

// A process owned by another user answers EPERM, not ESRCH. Reading that as "gone" would reclaim
// the ports of a cluster somebody else started on a shared test machine.
func TestTheRealProberTreatsEPERMAsAlive(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can signal anything, so there is no EPERM to observe")
	}
	if !(OSProber{}).Alive(Node{PID: 1}) {
		t.Error("pid 1 was reported dead; a permission error is not an absence")
	}
}
