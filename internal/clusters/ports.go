package clusters

import (
	"fmt"
	"sort"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// PortRange is a half-open-free, inclusive span of TCP ports one cluster holds.
type PortRange struct {
	Name string `json:"name"` // p2p, rpc, web3
	Base int    `json:"base"`
	// Count is the node count: node i listens on Base+i (build_chain's own convention).
	Count int `json:"count"`
}

func (r PortRange) Last() int { return r.Base + r.Count - 1 }

func (r PortRange) String() string {
	if r.Count == 1 {
		return fmt.Sprintf("%s:%d", r.Name, r.Base)
	}
	return fmt.Sprintf("%s:%d-%d", r.Name, r.Base, r.Last())
}

// Overlaps reports whether two ranges share any port. It deliberately ignores the names: a
// cluster's p2p range colliding with another cluster's rpc range is just as fatal as p2p meeting
// p2p, and comparing only like-for-like is the mistake that lets a default rpc base of 20200 sit
// inside somebody else's p2p span.
func (r PortRange) Overlaps(o PortRange) bool {
	return r.Base <= o.Last() && o.Base <= r.Last()
}

// DerivePorts computes the three ranges a cluster of nodeCount nodes occupies.
//
// The bases are inputs rather than constants because a profile's [config_ini_override] can move
// the web3 port, and --allow-parallel exists precisely so a second cluster can be given different
// ones.
func DerivePorts(nodeCount, p2p, rpc, web3 int) ([]PortRange, error) {
	if nodeCount < 1 {
		return nil, fbterr.Configf("a cluster needs at least one node, got %d", nodeCount)
	}
	out := []PortRange{
		{Name: "p2p", Base: p2p, Count: nodeCount},
		{Name: "rpc", Base: rpc, Count: nodeCount},
		{Name: "web3", Base: web3, Count: nodeCount},
	}
	for _, r := range out {
		if r.Base < 1 {
			return nil, fbterr.Configf("%s port base must be positive, got %d", r.Name, r.Base)
		}
		// The node count walks upward from the base, so a base that is itself legal can still put
		// the LAST node past the end of the port space. Left unchecked the chain simply fails to
		// bind, and the failure surfaces as an unexplained cluster that will not come up.
		if r.Last() > 65535 {
			return nil, fbterr.Configf("%s ports %d-%d exceed the port space: base %d with %d "+
				"nodes needs a port above 65535", r.Name, r.Base, r.Last(), r.Base, r.Count)
		}
	}
	// Within one cluster, too: a profile that moved web3 onto the rpc span would make the chain
	// fight itself, and nothing else would notice.
	if err := checkDisjoint(out); err != nil {
		return nil, err
	}
	return out, nil
}

func checkDisjoint(rs []PortRange) error {
	for i := 0; i < len(rs); i++ {
		for j := i + 1; j < len(rs); j++ {
			if rs[i].Overlaps(rs[j]) {
				return fbterr.Configf("this cluster's own %s and %s ranges overlap (%s, %s)",
					rs[i].Name, rs[j].Name, rs[i], rs[j])
			}
		}
	}
	return nil
}

// Conflicts returns every pair of ranges shared between a proposed cluster and an existing one.
func Conflicts(want, have []PortRange) []string {
	var out []string
	for _, w := range want {
		for _, h := range have {
			if w.Overlaps(h) {
				out = append(out, fmt.Sprintf("%s vs %s", w, h))
			}
		}
	}
	sort.Strings(out)
	return out
}

func describeConflicts(c []string) string { return strings.Join(c, ", ") }
