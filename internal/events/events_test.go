package events

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func fixedNow() time.Time { return time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC) }

func newNorm() *Normalizer {
	return &Normalizer{RunID: "run-1", ExpectedEventMajor: 1, Now: fixedNow}
}

func collect(t *testing.T, n *Normalizer, source, stream string) ([]Event, error) {
	t.Helper()
	var got []Event
	err := n.Read(source, strings.NewReader(stream), func(e Event) { got = append(got, e) })
	return got, err
}

// spec §8: the raw event carries only schema_version, ev and flat payload fields; run_id, seq, ts
// and source are the host's to add, because a global seq cannot be maintained by several
// independent bash processes.
func TestHostAddsTheEnvelopeAndKeepsPayloadFlat(t *testing.T) {
	got, err := collect(t, newNorm(), "gate.sh",
		`{"schema_version":"1.0.0","ev":"scenario_started","name":"malformed"}`+"\n"+
			`{"schema_version":"1.0.0","ev":"scenario_finished","name":"malformed","result":"pass"}`+"\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d events", len(got))
	}
	if got[0].Seq != 1 || got[1].Seq != 2 {
		t.Errorf("seq = %d,%d; want 1,2", got[0].Seq, got[1].Seq)
	}
	for i, e := range got {
		if e.RunID != "run-1" || e.Source != "gate.sh" || e.TS != fixedNow().UTC().Format(time.RFC3339Nano) {
			t.Errorf("event %d envelope = %+v", i, e)
		}
	}
	if got[0].Ev != "scenario_started" || got[0].Payload["name"] != "malformed" {
		t.Errorf("event 0 = %+v", got[0])
	}
	// schema_version and ev are envelope, not payload: leaving them in would duplicate them.
	for _, k := range []string{"ev", "schema_version"} {
		if _, dup := got[0].Payload[k]; dup {
			t.Errorf("%q was copied into the payload", k)
		}
	}
}

// A top-level "payload" key means the engine changed how it wraps events. Accepting it would
// produce silent double nesting, and every downstream field lookup would come back empty.
func TestTopLevelPayloadKeyIsAProtocolBreach(t *testing.T) {
	_, err := collect(t, newNorm(), "gate.sh",
		`{"schema_version":"1.0.0","ev":"x","payload":{"name":"y"}}`+"\n")
	assertHostError(t, err, "payload")
}

// "emit_event is a no-op when fd 3 is closed" only says events are not produced; it does not
// license a produced event to omit its version. The manifest proves what the engine claims, not
// what each event actually is.
func TestSchemaVersionIsRequiredAndCheckedPerEvent(t *testing.T) {
	for name, line := range map[string]string{
		"missing":     `{"ev":"x"}`,
		"not string":  `{"schema_version":1,"ev":"x"}`,
		"empty":       `{"schema_version":"","ev":"x"}`,
		"bad semver":  `{"schema_version":"one","ev":"x"}`,
		"wrong major": `{"schema_version":"2.0.0","ev":"x"}`,
	} {
		_, err := collect(t, newNorm(), "gate.sh", line+"\n")
		assertHostError(t, err, "schema_version")
		if err != nil && name == "wrong major" && !strings.Contains(err.Error(), "2.0.0") {
			t.Errorf("the error should quote the offending version, got %v", err)
		}
	}
	// A newer minor of the same major stays compatible.
	if _, err := collect(t, newNorm(), "gate.sh", `{"schema_version":"1.7.3","ev":"x"}`+"\n"); err != nil {
		t.Errorf("a newer minor must be accepted: %v", err)
	}
}

func TestEvIsRequired(t *testing.T) {
	for _, line := range []string{`{"schema_version":"1.0.0"}`, `{"schema_version":"1.0.0","ev":""}`,
		`{"schema_version":"1.0.0","ev":7}`} {
		_, err := collect(t, newNorm(), "gate.sh", line+"\n")
		assertHostError(t, err, "ev")
	}
}

func TestNonObjectAndMalformedLinesAreHostErrors(t *testing.T) {
	for _, stream := range []string{"[1,2]\n", `"a string"` + "\n", "{not json}\n", "null\n"} {
		_, err := collect(t, newNorm(), "gate.sh", stream)
		assertHostError(t, err, "")
	}
}

// Block heights and wei amounts exceed float64's exact range. Decoding them as float64 would
// silently round, and the golden event fixtures would stop matching the chain.
func TestLargeIntegersKeepTheirExactText(t *testing.T) {
	const big = "12345678901234567890"
	got, err := collect(t, newNorm(), "fuzz_bcos.sh",
		`{"schema_version":"1.0.0","ev":"fuzz_batch","height":`+big+`}`+"\n")
	if err != nil {
		t.Fatal(err)
	}
	num, ok := got[0].Payload["height"].(json.Number)
	if !ok {
		t.Fatalf("height decoded as %T, want json.Number (is UseNumber set?)", got[0].Payload["height"])
	}
	if num.String() != big {
		t.Errorf("height = %s, want %s", num, big)
	}
}

// Nested objects inside a payload field are fine -- fuzz_batch carries a tally object. Only a
// top-level key literally named payload is the breach.
func TestNestedPayloadValuesAreAllowed(t *testing.T) {
	got, err := collect(t, newNorm(), "fuzz_bcos.sh",
		`{"schema_version":"1.0.0","ev":"fuzz_batch","idx":1,"tally":{"accepted":27,"rejected":33}}`+"\n")
	if err != nil {
		t.Fatal(err)
	}
	tally, ok := got[0].Payload["tally"].(map[string]interface{})
	if !ok || tally["accepted"].(json.Number).String() != "27" {
		t.Errorf("tally = %#v", got[0].Payload["tally"])
	}
}

func TestEmptyStreamIsNotAnError(t *testing.T) {
	for _, s := range []string{"", "\n\n", "   \n"} {
		got, err := collect(t, newNorm(), "gate.sh", s)
		if err != nil || len(got) != 0 {
			t.Errorf("stream %q: got %d events, %v", s, len(got), err)
		}
	}
}

// spec §8: seq allocation and delivery must happen in one critical section. If they did not, two
// engine processes writing fd 3 could deliver event 7 before event 6, and a golden event-stream
// fixture would stop being reproducible.
func TestSeqIsUniqueAndDeliveredInOrderUnderConcurrency(t *testing.T) {
	const readers, perReader = 8, 40
	n := newNorm()

	var mu sync.Mutex
	var delivered []int64
	sink := func(e Event) {
		mu.Lock()
		delivered = append(delivered, e.Seq)
		mu.Unlock()
	}

	var stream strings.Builder
	for i := 0; i < perReader; i++ {
		fmt.Fprintf(&stream, `{"schema_version":"1.0.0","ev":"tick","i":%d}`+"\n", i)
	}

	var wg sync.WaitGroup
	for r := 0; r < readers; r++ {
		wg.Add(1)
		go func(r int) {
			defer wg.Done()
			if err := n.Read(fmt.Sprintf("src-%d", r), strings.NewReader(stream.String()), sink); err != nil {
				t.Errorf("reader %d: %v", r, err)
			}
		}(r)
	}
	wg.Wait()

	if len(delivered) != readers*perReader {
		t.Fatalf("delivered %d events, want %d", len(delivered), readers*perReader)
	}
	// The sink appends in delivery order; if seq were allocated outside the delivery lock, this
	// slice would not be monotonic.
	seen := map[int64]bool{}
	for i, s := range delivered {
		if seen[s] {
			t.Fatalf("seq %d was handed out twice", s)
		}
		seen[s] = true
		if i > 0 && s <= delivered[i-1] {
			t.Fatalf("delivery order %v is not monotonic at %d", delivered[max0(i-3):i+1], i)
		}
	}
}

func max0(i int) int {
	if i < 0 {
		return 0
	}
	return i
}

// Read stops at the first bad event: continuing would deliver events with gaps in seq that no
// consumer could distinguish from a lost event.
func TestReadStopsAtTheFirstBadEvent(t *testing.T) {
	got, err := collect(t, newNorm(), "gate.sh",
		`{"schema_version":"1.0.0","ev":"ok1"}`+"\n"+
			`{"ev":"no_version"}`+"\n"+
			`{"schema_version":"1.0.0","ev":"ok2"}`+"\n")
	assertHostError(t, err, "schema_version")
	if len(got) != 1 || got[0].Ev != "ok1" {
		t.Errorf("got %+v, want only the event before the breach", got)
	}
}

// Now defaults to the wall clock rather than panicking, so a caller that forgets to set it gets a
// usable timestamp instead of a crash mid-run.
func TestNowDefaultsToTheWallClock(t *testing.T) {
	n := &Normalizer{RunID: "r", ExpectedEventMajor: 1}
	got, err := collect(t, n, "gate.sh", `{"schema_version":"1.0.0","ev":"x"}`+"\n")
	if err != nil {
		t.Fatal(err)
	}
	if _, perr := time.Parse(time.RFC3339Nano, got[0].TS); perr != nil {
		t.Errorf("ts = %q is not RFC3339: %v", got[0].TS, perr)
	}
}

func assertHostError(t *testing.T, err error, mustMention string) {
	t.Helper()
	if err == nil {
		t.Fatal("want an error")
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassHost {
		t.Errorf("want ClassHost (exit 40), got %v (err=%v)", c, err)
	}
	if mustMention != "" && !strings.Contains(err.Error(), mustMention) {
		t.Errorf("the error should mention %q, got %v", mustMention, err)
	}
}
