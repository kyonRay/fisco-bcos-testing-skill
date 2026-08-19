package clusters

import "testing"

type fakeFinger struct{}

func (fakeFinger) Alive(Node) bool            { return true }
func (fakeFinger) Fingerprint(pid int) string { return "started-" + itoa(pid) }

const ws = "/state/runs/R1/cluster"

func TestParsePgrepNamesEveryNode(t *testing.T) {
	out := "1001 " + ws + "/127.0.0.1/node0/../fisco-bcos -c config.ini\n" +
		"1002 " + ws + "/127.0.0.1/node1/../fisco-bcos -c config.ini\n"
	got := parsePgrep(out, 999, fakeFinger{})
	if len(got) != 2 {
		t.Fatalf("got %d nodes, want 2: %+v", len(got), got)
	}
	if got[0].Name != "node0" || got[1].Name != "node1" {
		t.Errorf("names = %q %q", got[0].Name, got[1].Name)
	}
	// The fingerprint is what makes a reused PID detectable later. Registering without one silently
	// downgrades liveness to a bare PID check.
	if got[0].Start != "started-1001" {
		t.Errorf("Start = %q, want the fingerprint taken at registration", got[0].Start)
	}
}

// fbt's own argv can name the workspace it just built. Registering the host as one of the chain's
// nodes would make the entry read alive for as long as fbt runs, and stale the moment it exits.
func TestParsePgrepSkipsOurOwnProcess(t *testing.T) {
	out := "999 fbt --state-dir /state cluster up -o " + ws + "/x\n" +
		"1001 " + ws + "/127.0.0.1/node0/../fisco-bcos\n"
	got := parsePgrep(out, 999, fakeFinger{})
	if len(got) != 1 || got[0].PID != 1001 {
		t.Fatalf("got %+v, want only the node", got)
	}
}

// A shell that merely mentions the workspace is not a node. Counting one makes a fully dead
// cluster read as degraded -- and degraded clusters are deliberately never reclaimed, so the
// ports would be held forever.
func TestParsePgrepCountsOnlyTheNodeBinary(t *testing.T) {
	out := "1001 tail -f " + ws + "/127.0.0.1/node0/log/log\n" +
		"1002 " + ws + "/127.0.0.1/node0/../fisco-bcos\n"
	got := parsePgrep(out, 999, fakeFinger{})
	if len(got) != 1 || got[0].PID != 1002 {
		t.Fatalf("got %+v, want only the fisco-bcos process", got)
	}
}

// An entry with real nodes is what makes every other status reachable. This is the assertion that
// ties discovery to the machinery it feeds.
func TestDiscoveredNodesMakeTheEntryActiveRatherThanUnknown(t *testing.T) {
	out := "1001 " + ws + "/127.0.0.1/node0/../fisco-bcos\n"
	nodes := parsePgrep(out, 999, fakeFinger{})
	if s := statusOf(nodes, fakeFinger{}); s != StatusActive {
		t.Errorf("status = %v, want active; with no nodes it stays unknown forever", s)
	}
	if s := statusOf(nil, fakeFinger{}); s != StatusUnknown {
		t.Errorf("empty status = %v, want unknown (the state this fixes)", s)
	}
}
