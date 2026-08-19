package clusters

import (
	"fmt"
	"net"
	"strconv"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Occupied reports which of these ports already have a listener.
//
// The registry answers "are these ports free" for clusters FBT built, and only those. A machine
// that already runs a chain -- the normal state of a CI runner -- is invisible to it. That gap is
// not theoretical: a run whose ports collided got as far as copying a 651MB binary and starting
// four nodes, roughly ninety seconds, before every one of them died on
//
//	bind: Address already in use
//
// The engine's own check then correctly refused to call a 0-of-4 cluster up, so the verdict was
// right; it was just expensive and said nothing about which port was taken.
//
// The probe binds the same way a node does -- all interfaces, not the loopback alone. build_chain
// generates listen addresses on 0.0.0.0, and a listener held on 127.0.0.1 only would still make
// that bind fail while a loopback-only probe called the port free.
func Occupied(rs []PortRange) []int {
	var out []int
	for _, r := range rs {
		for p := r.Base; p <= r.Last(); p++ {
			if !portFree(p) {
				out = append(out, p)
			}
		}
	}
	return out
}

func portFree(port int) bool {
	l, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		return false
	}
	_ = l.Close()
	return true
}

// CheckFree refuses a port set somebody else is already holding.
//
// Infrastructure, not configuration: the ports the operator chose are legal, the machine is busy.
// Reaching the same collision through the engine produces 30, and a preflight that classified it
// differently would make the same failure mean two different things depending on how far the run
// got.
func CheckFree(rs []PortRange) error {
	busy := Occupied(rs)
	if len(busy) == 0 {
		return nil
	}
	names := make([]string, 0, len(busy))
	for _, p := range busy {
		names = append(names, strconv.Itoa(p))
	}
	return fbterr.Infraf("%s already in use on this machine: %s. Something else is listening "+
		"there -- another chain, or a cluster fbt did not build. Move the cluster with "+
		"cluster.p2p_base_port / cluster.bcos_base_port / cluster.web3_base_port, or stop it",
		plural(len(busy), "port", "ports"), strings.Join(names, ", "))
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}
