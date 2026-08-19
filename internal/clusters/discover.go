package clusters

import (
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// nodeName pulls node0 / node12 out of a fisco-bcos command line. build_chain lays a cluster out as
// <workspace>/127.0.0.1/node<i>/, and the node runs with that directory in its argv.
var nodeName = regexp.MustCompile(`/(node\d+)/`)

// DiscoverNodes finds the node processes belonging to one cluster workspace.
//
// Without this every persistent entry registers zero nodes, and statusOf reports Unknown forever:
// the cluster can never be seen as active, never be found stale, and never be reclaimed after a
// crash. The whole liveness and PID-reuse apparatus sits unused behind an empty slice. It went
// unnoticed while `gate run` was the only thing that built clusters, because it released its
// reservation on the way out regardless.
//
// Matching is by workspace path, which is what keeps one cluster's discovery from picking up
// another's -- two chains on one machine differ in their node directories, not in their binary.
func DiscoverNodes(workspace string, p Prober) []Node {
	out, err := exec.Command("pgrep", "-af", workspace+string(os.PathSeparator)).Output()
	if err != nil {
		// pgrep exits 1 when nothing matches, which is a real answer: no nodes are running.
		return nil
	}
	return parsePgrep(string(out), os.Getpid(), p)
}

// parsePgrep is the pure half, so the parsing is testable without spawning a chain.
func parsePgrep(out string, self int, p Prober) []Node {
	var nodes []Node
	seen := map[int]bool{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		pidStr, cmd, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		pid, err := strconv.Atoi(pidStr)
		// Skip our own process: fbt's argv can name the workspace it just built, and registering
		// the host as one of the chain's nodes would make the entry look alive for as long as fbt
		// runs and stale the instant it exits.
		if err != nil || pid <= 0 || pid == self || seen[pid] {
			continue
		}
		// Only the node binary. A shell that happens to mention the workspace is not a node, and
		// counting one would make a fully dead cluster read as degraded and never be reclaimed.
		if !strings.Contains(cmd, "fisco-bcos") {
			continue
		}
		seen[pid] = true
		name := ""
		if m := nodeName.FindStringSubmatch(cmd); m != nil {
			name = m[1]
		}
		nodes = append(nodes, Node{Name: name, PID: pid, Start: p.Fingerprint(pid)})
	}
	return nodes
}
