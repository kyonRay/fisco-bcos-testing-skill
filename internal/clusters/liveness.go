package clusters

import (
	"os/exec"
	"strings"
	"syscall"
)

// Node is one registered node process.
type Node struct {
	Name string `json:"name"`
	PID  int    `json:"pid"`
	// Start is the process's start time as `ps -o lstart=` reports it, captured at registration.
	//
	// A bare PID is not an identity. PIDs are reused, and both directions of that mistake hurt: a
	// reused PID makes a dead cluster look alive, so fbt refuses to run forever; and treating a
	// live cluster as dead makes fbt reclaim its ports, so two chains then fight over 30300 and the
	// resulting failures point nowhere near the cause. The start time settles it -- the only way to
	// fool it is to reuse a PID within the same second, which the kernel's sequential allocation
	// makes effectively impossible.
	//
	// Empty means the fingerprint could not be taken. Liveness then falls back to the PID alone,
	// which is weaker, and says so rather than pretending otherwise.
	Start string `json:"start,omitempty"`
}

// Prober answers whether a registered process is still the process that was registered. It is an
// interface so tests can drive stale, live and reused-PID states without spawning real processes.
type Prober interface {
	Alive(n Node) bool
	Fingerprint(pid int) string
}

// OSProber is the real implementation.
type OSProber struct{}

// Alive reports whether the process exists AND is the same one that was registered.
func (OSProber) Alive(n Node) bool {
	if n.PID <= 0 {
		return false
	}
	// Signal 0 performs the existence and permission check without delivering anything.
	if err := syscall.Kill(n.PID, 0); err != nil {
		// EPERM means the process exists but belongs to someone else -- it is alive, and treating
		// it as gone would reclaim ports it is still holding.
		if err != syscall.EPERM {
			return false
		}
	}
	if n.Start == "" {
		return true // no fingerprint was ever taken; the PID is all there is
	}
	now := OSProber{}.Fingerprint(n.PID)
	if now == "" {
		// The process disappeared between the signal and the ps call, or ps is unavailable. Erring
		// toward "alive" keeps fbt from reclaiming ports a live chain may still hold.
		return true
	}
	return now == n.Start
}

// Fingerprint returns a string that changes when a PID is reused. An empty result means the
// fingerprint could not be taken -- the caller records that rather than substituting a fake one,
// so a later comparison cannot silently succeed against a placeholder.
func (OSProber) Fingerprint(pid int) string {
	if pid <= 0 {
		return ""
	}
	// lstart is supported by both BSD ps (macOS) and procps (Linux) and has one-second resolution.
	out, err := exec.Command("ps", "-p", itoa(pid), "-o", "lstart=").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// Status is what a registry entry's processes say about it.
type Status string

const (
	// StatusActive: every registered node is still running. The reservation stands.
	StatusActive Status = "active"
	// StatusStale: no registered node is running. The entry is a crash leftover and fbt reclaims
	// it automatically, because otherwise one crash holds the machine's ports forever.
	StatusStale Status = "stale"
	// StatusDegraded: SOME nodes are running. Deliberately not reclaimed.
	//
	// A partially dead cluster still holds the ports of its survivors, so reclaiming it would hand
	// those ports to a new run and produce two chains bound to overlapping ranges. It is also
	// exactly what a consensus-halt investigation wants to find intact. It counts as active for
	// locking and is reported separately so `cluster ls` can show it for what it is.
	StatusDegraded Status = "degraded"
	// StatusUnknown: the entry registered no nodes at all -- a cluster that was recorded before its
	// processes started, or one whose registration was interrupted. Treated as active, because
	// assuming it holds nothing is the assumption that reclaims a live cluster's ports.
	StatusUnknown Status = "unknown"
)

// Live reports whether a status holds ports. Only a fully stale entry does not.
func (s Status) Live() bool { return s != StatusStale }

func statusOf(nodes []Node, p Prober) Status {
	if len(nodes) == 0 {
		return StatusUnknown
	}
	alive := 0
	for _, n := range nodes {
		if p.Alive(n) {
			alive++
		}
	}
	switch alive {
	case 0:
		return StatusStale
	case len(nodes):
		return StatusActive
	default:
		return StatusDegraded
	}
}
