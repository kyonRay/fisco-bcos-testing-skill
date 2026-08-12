package fbterr

import (
	"errors"
	"fmt"
	"testing"
)

func TestClassOfRecognizesEachConstructor(t *testing.T) {
	for _, c := range []struct {
		err  error
		want Class
	}{
		{Configf("bad key %q", "x"), ClassConfig},
		{Infraf("missing %s", "console"), ClassInfra},
		{Hostf("protocol %d", 2), ClassHost},
	} {
		got, ok := ClassOf(c.err)
		if !ok || got != c.want {
			t.Errorf("ClassOf(%v) = %v,%v; want %v,true", c.err, got, ok, c.want)
		}
	}
}

// A plain error carries no class: the caller must decide, rather than defaulting to something
// that silently becomes a passing exit code.
func TestClassOfPlainErrorReportsNotClassified(t *testing.T) {
	if _, ok := ClassOf(errors.New("plain")); ok {
		t.Error("a plain error must report ok=false")
	}
	if _, ok := ClassOf(nil); ok {
		t.Error("nil must report ok=false")
	}
}

// Classification must survive %w wrapping: errors cross three package boundaries before the CLI
// maps them to an exit code.
func TestClassSurvivesWrapping(t *testing.T) {
	doubly := fmt.Errorf("config show: %w", fmt.Errorf("loading manifest: %w", Infraf("unreachable")))
	got, ok := ClassOf(doubly)
	if !ok || got != ClassInfra {
		t.Errorf("ClassOf through two wraps = %v,%v; want ClassInfra,true", got, ok)
	}
}

func TestWrapAttachesClassAndPreservesUnwrap(t *testing.T) {
	base := errors.New("permission denied")
	err := Wrap(base, ClassInfra)
	if got, ok := ClassOf(err); !ok || got != ClassInfra {
		t.Fatalf("ClassOf = %v,%v", got, ok)
	}
	if !errors.Is(err, base) {
		t.Error("Wrap must keep the original error reachable via errors.Is")
	}
	if Wrap(nil, ClassInfra) != nil {
		t.Error("Wrap(nil) must stay nil")
	}
}

// The innermost class wins: an outer layer adding context must not reclassify the real failure.
func TestInnermostClassWins(t *testing.T) {
	err := fmt.Errorf("outer: %w", Infraf("inner"))
	if got, _ := ClassOf(err); got != ClassInfra {
		t.Errorf("got %v, want ClassInfra", got)
	}
}
