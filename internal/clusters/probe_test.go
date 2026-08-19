package clusters

import (
	"net"
	"strconv"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// listenOn takes a port and holds it, the way a chain already running on this machine does.
func listenOn(t *testing.T) (int, func()) {
	t.Helper()
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Skipf("cannot listen on this machine: %v", err)
	}
	_, p, _ := net.SplitHostPort(l.Addr().String())
	n, _ := strconv.Atoi(p)
	return n, func() { _ = l.Close() }
}

// The registry only knows the clusters fbt built. A machine already running a chain -- the normal
// state of a CI runner -- is invisible to it, and the collision surfaced 90 seconds later as four
// nodes dying on "Address already in use", after build_chain had copied a 651MB binary.
func TestOccupiedFindsAPortSomebodyElseHolds(t *testing.T) {
	port, done := listenOn(t)
	defer done()

	busy := Occupied([]PortRange{{Name: "rpc", Base: port, Count: 1}})
	if len(busy) != 1 || busy[0] != port {
		t.Fatalf("Occupied = %v, want [%d]", busy, port)
	}
}

func TestOccupiedSaysNothingAboutFreePorts(t *testing.T) {
	port, done := listenOn(t)
	done() // release it again

	if busy := Occupied([]PortRange{{Name: "rpc", Base: port, Count: 1}}); len(busy) != 0 {
		t.Errorf("Occupied = %v on a released port", busy)
	}
}

// It has to be infra, not config: the ports are fine, the machine is occupied. The same collision
// reached through the engine produced 30, and the preflight must not disagree with it.
func TestCheckFreeReportsInfraAndNamesThePort(t *testing.T) {
	port, done := listenOn(t)
	defer done()

	err := CheckFree([]PortRange{{Name: "rpc", Base: port, Count: 1}})
	if err == nil {
		t.Fatal("an occupied port passed the check")
	}
	if c, _ := fbterr.ClassOf(err); c != fbterr.ClassInfra {
		t.Errorf("class = %v, want infra", c)
	}
	if !strings.Contains(err.Error(), strconv.Itoa(port)) {
		t.Errorf("err = %v; it must name the port so the fix is obvious", err)
	}
}

// Probing every port of a 4-node cluster is 12 binds. It must scan the whole set rather than stop
// at the first hit -- an operator moving ports wants to know all of them, not one per attempt.
func TestCheckFreeReportsEveryOccupiedPort(t *testing.T) {
	a, doneA := listenOn(t)
	defer doneA()
	b, doneB := listenOn(t)
	defer doneB()

	busy := Occupied([]PortRange{
		{Name: "p2p", Base: a, Count: 1},
		{Name: "rpc", Base: b, Count: 1},
	})
	if len(busy) != 2 {
		t.Fatalf("Occupied = %v, want both %d and %d", busy, a, b)
	}
}
