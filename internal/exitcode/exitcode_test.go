package exitcode

import (
	"sync"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func TestFromClassAndFromError(t *testing.T) {
	for cl, want := range map[fbterr.Class]Code{
		fbterr.ClassConfig: Config, fbterr.ClassInfra: Infra, fbterr.ClassHost: Host,
	} {
		if got := FromClass(cl); got != want {
			t.Errorf("FromClass(%v) = %d, want %d", cl, got, want)
		}
	}
	if got := FromError(nil); got != OK {
		t.Errorf("FromError(nil) = %d, want 0", got)
	}
	if got := FromError(fbterr.Infraf("x")); got != Infra {
		t.Errorf("FromError(infra) = %d, want 30", got)
	}
}

func TestFromOutcomeMapping(t *testing.T) {
	for outcome, want := range map[string]Code{
		"pass": OK, "gate_fail": GateFail, "config_error": Config,
		"infra_error": Infra, "engine_error": Host,
	} {
		if got := FromOutcome(outcome); got != want {
			t.Errorf("FromOutcome(%q) = %d, want %d", outcome, got, want)
		}
	}
	if got := FromOutcome("nonsense"); got != Host {
		t.Errorf("an unrecognized outcome must be a host error, got %d", got)
	}
}

func TestSeverityPriority(t *testing.T) {
	a := &Aggregator{}
	a.Add(GateFail)
	a.Add(Config)
	if got := a.Result(); got != Config {
		t.Errorf("got %d, want 20: a config error makes the gate verdict untrustworthy", got)
	}
	a.Add(Host)
	if got := a.Result(); got != Host {
		t.Errorf("got %d, want 40", got)
	}
}

func TestOKDoesNotDowngradeAnEarlierFailure(t *testing.T) {
	a := &Aggregator{}
	a.Add(GateFail)
	a.Add(OK)
	if got := a.Result(); got != GateFail {
		t.Errorf("got %d, want 10", got)
	}
}

// spec §9: the host kills the process group on timeout; that death must not become a host bug.
func TestTimeoutSurvivesTheKillItCaused(t *testing.T) {
	a := &Aggregator{}
	a.MarkTimeout()
	a.AddSignalDeath()
	if got := a.Result(); got != Infra {
		t.Errorf("got %d, want 30", got)
	}
}

// ...but a GENUINE host error after a timeout must still surface, or a real defect hides behind
// an unrelated slow chain.
func TestRealHostErrorAfterTimeoutIsNotSwallowed(t *testing.T) {
	a := &Aggregator{}
	a.MarkTimeout()
	a.Add(Host)
	if got := a.Result(); got != Host {
		t.Errorf("got %d, want 40", got)
	}
}

func TestSignalDeathWithoutTimeoutIsHostError(t *testing.T) {
	a := &Aggregator{}
	a.AddSignalDeath()
	if got := a.Result(); got != Host {
		t.Errorf("got %d, want 40", got)
	}
}

func TestCanceledBeatsEverything(t *testing.T) {
	a := &Aggregator{}
	a.Add(Host)
	a.MarkTimeout()
	a.MarkCanceled()
	if got := a.Result(); got != Canceled {
		t.Errorf("got %d, want 130", got)
	}
}

// The six-code contract must hold even if a caller passes something outside it.
func TestUnknownCodeIsNormalizedToHost(t *testing.T) {
	a := &Aggregator{}
	a.Add(Code(99))
	if got := a.Result(); got != Host {
		t.Errorf("got %d, want 40: only the six documented codes may leave the process", got)
	}
}

func TestEmptyAggregatorIsClean(t *testing.T) {
	if got := (&Aggregator{}).Result(); got != OK {
		t.Errorf("got %d, want 0", got)
	}
}

// 1B drives one reader goroutine per engine subprocess plus a timeout timer.
func TestAggregatorIsConcurrencySafe(t *testing.T) {
	a := &Aggregator{}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				switch i % 4 {
				case 0:
					a.Add(GateFail)
				case 1:
					a.AddSignalDeath()
				case 2:
					a.MarkTimeout()
				default:
					_ = a.Result()
				}
			}
		}(i)
	}
	wg.Wait()
	if got := a.Result(); got != Infra && got != Host {
		t.Errorf("unexpected aggregate %d", got)
	}
}
