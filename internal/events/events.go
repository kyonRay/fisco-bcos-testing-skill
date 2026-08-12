// Package events reads the engine's fd 3 JSON-Lines stream and normalizes it (spec §8).
//
// The raw event carries only schema_version, ev and flat payload fields. run_id, seq, ts and
// source are added here, because a global sequence number cannot be maintained by several
// independent bash processes writing the same pipe.
package events

import (
	"encoding/json"
	"io"
	"sync"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/engine"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Event is one normalized event: the envelope the host owns, plus the engine's flat fields.
type Event struct {
	SchemaVersion string                 `json:"schema_version"`
	Ev            string                 `json:"ev"`
	RunID         string                 `json:"run_id"`
	Seq           int64                  `json:"seq"`
	TS            string                 `json:"ts"`
	Source        string                 `json:"source"`
	Payload       map[string]interface{} `json:"payload,omitempty"`
}

// Normalizer is shared by every engine subprocess of one run: the sequence number is global, so
// each process cannot own its own counter.
//
// ExpectedEventMajor comes from the already-verified engine.json (engine.Manifest.EventMajor()).
// Checking the manifest proves what the engine claims; checking every event proves what it
// actually sent.
type Normalizer struct {
	RunID              string
	ExpectedEventMajor int
	Now                func() time.Time // defaults to time.Now

	mu  sync.Mutex
	seq int64
}

// Read consumes a JSON-Lines stream and hands each normalized event to sink. It returns on EOF, or
// on the first protocol breach -- continuing past one would deliver events with gaps in seq that a
// consumer could not tell apart from events lost in transit.
//
// Every failure here is a host error (exit 40): the engine and the host disagree about the
// protocol, which is a bug in one of them, not something the user configured wrong.
func (n *Normalizer) Read(source string, r io.Reader, sink func(Event)) error {
	dec := json.NewDecoder(r)
	// Block heights and wei amounts exceed float64's exact integer range; decoding them as
	// float64 would silently round them.
	dec.UseNumber()

	for {
		var raw map[string]interface{}
		err := dec.Decode(&raw)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fbterr.Hostf("fd 3 stream from %s is not JSON-Lines: %v", source, err)
		}
		if raw == nil {
			// `null` decodes into a nil map without error, which is not an event.
			return fbterr.Hostf("fd 3 stream from %s carried a null where an event object was "+
				"expected", source)
		}
		e, err := n.normalize(source, raw)
		if err != nil {
			return err
		}
		// seq allocation and delivery share one critical section (spec §8). Splitting them would
		// let two engine processes deliver event 7 before event 6, and a golden event-stream
		// fixture would stop being reproducible.
		n.mu.Lock()
		n.seq++
		e.Seq = n.seq
		sink(e)
		n.mu.Unlock()
	}
}

func (n *Normalizer) normalize(source string, raw map[string]interface{}) (Event, error) {
	// spec §8: a top-level "payload" key means the engine changed how it wraps events. Accepting
	// it would produce silent double nesting and every downstream field lookup would come back
	// empty.
	if _, nested := raw["payload"]; nested {
		return Event{}, fbterr.Hostf("event from %s has a top-level \"payload\" key: fd 3 events "+
			"must be flat, and a nested envelope would hide every field from downstream consumers",
			source)
	}

	version, ok := raw["schema_version"].(string)
	if !ok || version == "" {
		return Event{}, fbterr.Hostf("event from %s has no string schema_version (%v); it is "+
			"mandatory on every event, not only in engine.json", source, raw["schema_version"])
	}
	major, _, _, err := engine.ParseSemver(version)
	if err != nil {
		return Event{}, fbterr.Hostf("event from %s has an unparseable schema_version %q: %v",
			source, version, err)
	}
	if major != n.ExpectedEventMajor {
		return Event{}, fbterr.Hostf("event from %s declares schema_version %q, but the engine "+
			"manifest promised event schema major %d", source, version, n.ExpectedEventMajor)
	}

	ev, ok := raw["ev"].(string)
	if !ok || ev == "" {
		return Event{}, fbterr.Hostf("event from %s has no string \"ev\" name (%v)", source, raw["ev"])
	}

	// Everything else is payload. schema_version and ev stay out of it: they are envelope, and
	// copying them in would give every consumer two spellings of the same field.
	payload := make(map[string]interface{}, len(raw))
	for k, v := range raw {
		if k == "ev" || k == "schema_version" {
			continue
		}
		payload[k] = v
	}
	if len(payload) == 0 {
		payload = nil
	}

	now := n.Now
	if now == nil {
		now = time.Now
	}
	return Event{
		SchemaVersion: version,
		Ev:            ev,
		RunID:         n.RunID,
		TS:            now().UTC().Format(time.RFC3339Nano),
		Source:        source,
		Payload:       payload,
	}, nil
}
