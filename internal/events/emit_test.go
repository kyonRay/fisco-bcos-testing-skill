package events

import (
	"strings"
	"sync"
	"testing"
)

func TestHostEventsShareTheEngineSequence(t *testing.T) {
	n := &Normalizer{RunID: "r1", ExpectedEventMajor: 1}
	var got []Event
	sink := func(e Event) { got = append(got, e) }

	n.Emit("run_started", map[string]interface{}{"run_id": "r1"}, sink)
	if err := n.Read("gate.sh", strings.NewReader(
		`{"schema_version":"1.0.0","ev":"command_started","cmd":"gate.sh"}`+"\n"+
			`{"schema_version":"1.0.0","ev":"command_finished","cmd":"gate.sh","outcome":"pass"}`+"\n"),
		sink); err != nil {
		t.Fatal(err)
	}
	n.Emit("run_finished", map[string]interface{}{"exit": 0}, sink)

	// One ordering, not two. If the host kept its own counter, seq would read 1,1,2,2 and a
	// consumer sorting by seq could not tell whether the run opened before or after the command.
	wantSeq := []int64{1, 2, 3, 4}
	wantEv := []string{"run_started", "command_started", "command_finished", "run_finished"}
	if len(got) != 4 {
		t.Fatalf("got %d events, want 4", len(got))
	}
	for i, e := range got {
		if e.Seq != wantSeq[i] || e.Ev != wantEv[i] {
			t.Errorf("event %d = {seq:%d ev:%s}, want {seq:%d ev:%s}",
				i, e.Seq, e.Ev, wantSeq[i], wantEv[i])
		}
		if e.RunID != "r1" || e.TS == "" {
			t.Errorf("event %d has an incomplete envelope: %+v", i, e)
		}
	}
	if got[0].Source != HostSource || got[1].Source != "gate.sh" {
		t.Errorf("sources = %q/%q; a reader must be able to tell the two sides apart",
			got[0].Source, got[1].Source)
	}
}

// The host validates every engine event against ExpectedEventMajor. Stamping its own events with a
// different major would put two incompatible framings in one stream.
func TestHostEventsCarryTheHostsOwnMajor(t *testing.T) {
	n := &Normalizer{RunID: "r", ExpectedEventMajor: 2}
	var got Event
	n.Emit("run_started", nil, func(e Event) { got = e })
	if got.SchemaVersion != "2.0.0" {
		t.Errorf("schema_version = %q, want 2.0.0", got.SchemaVersion)
	}
	if got.Payload != nil {
		t.Errorf("an empty payload must stay absent, got %v", got.Payload)
	}
}

// One reader goroutine per engine subprocess plus the host's own emits means concurrent callers.
// Run with -race; without the shared lock this hands out duplicate sequence numbers.
func TestConcurrentEmittersGetDistinctSequenceNumbers(t *testing.T) {
	n := &Normalizer{RunID: "r", ExpectedEventMajor: 1}
	var mu sync.Mutex
	seen := map[int64]bool{}
	sink := func(e Event) {
		mu.Lock()
		defer mu.Unlock()
		if seen[e.Seq] {
			t.Errorf("seq %d handed out twice", e.Seq)
		}
		seen[e.Seq] = true
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				n.Emit("tick", nil, sink)
			}
		}()
	}
	wg.Wait()
	if len(seen) != 400 {
		t.Errorf("got %d distinct sequence numbers, want 400", len(seen))
	}
}
