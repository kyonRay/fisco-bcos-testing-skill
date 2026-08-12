package execution

import (
	"fmt"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/events"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// terminator is the one command_finished that closes the command the host launched. Its outcome is
// the authoritative verdict (spec §8): the host maps its exit code from that field alone and never
// infers the result from whichever diagnostic `error` events happened to precede it.
type terminator struct {
	Outcome    string
	EngineExit int
	Signal     string
}

// tracker follows the command_started / command_finished protocol on ONE subprocess's fd 3 stream.
//
// The stream is not flat. gate.sh launches apply_profile.sh as a subprocess, which inherits fd 3
// and emits its own pair -- so the host sees nested frames and must not mistake the inner
// command_finished for the outer one's terminator. The frames are a stack, and only the event that
// empties it terminates the command the host started.
type tracker struct {
	root      string // the cmd name the launched script must announce
	stack     []string
	term      *terminator
	abandoned []string // frames a later terminator unwound past: an engine subprocess that died hard
	breach    error    // the FIRST protocol breach; later ones add nothing
}

func newTracker(root string) *tracker { return &tracker{root: root} }

// Observe folds one normalized event into the state machine. It never returns an error: a breach is
// recorded and the stream keeps being read, because the remaining events still go to the --output
// jsonl consumer and the stderr tail is still worth collecting.
func (t *tracker) Observe(e events.Event) {
	switch e.Ev {
	case "command_started":
		cmd := stringField(e, "cmd")
		if len(t.stack) == 0 && cmd != t.root {
			// The wrapper forgot to name itself, or the host launched a different script than it
			// thinks. Either way the terminator below cannot be matched to anything.
			t.fail(fbterr.Hostf("the host launched %s but the engine announced starting %q",
				t.root, cmd))
		}
		t.stack = append(t.stack, cmd)

	case "command_finished":
		cmd := stringField(e, "cmd")
		idx := lastIndex(t.stack, cmd)
		if idx < 0 {
			t.fail(fbterr.Hostf("the engine reported %s finishing, but no command_started for it "+
				"was ever seen", quote(cmd)))
			return
		}
		// Unwind to the matching frame. A nested script KILLed mid-run leaves its frame open
		// forever; treating that as a fatal breach would report fbt's own bug for an engine
		// subprocess that died. The abandoned names are kept and surface in the failure reason.
		t.abandoned = append(t.abandoned, t.stack[idx+1:]...)
		t.stack = t.stack[:idx]
		if len(t.stack) > 0 {
			return // a nested command finished; the host's own command is still running
		}
		if t.term != nil {
			t.fail(fbterr.Hostf("%s reported command_finished twice; exactly one terminating "+
				"event per launched command is what the exit code is derived from", t.root))
			return
		}
		t.term = &terminator{
			Outcome:    stringField(e, "outcome"),
			EngineExit: intField(e, "engine_exit"),
			Signal:     stringField(e, "signal"),
		}
	}
}

func (t *tracker) fail(err error) {
	if t.breach == nil {
		t.breach = err
	}
}

func lastIndex(stack []string, name string) int {
	for i := len(stack) - 1; i >= 0; i-- {
		if stack[i] == name {
			return i
		}
	}
	return -1
}

// stringField reads a payload field that must be a string. A field of the wrong type reads as
// absent rather than panicking: the classifier's job is to report the protocol breach, not to die
// of it.
func stringField(e events.Event, name string) string {
	if v, ok := e.Payload[name].(string); ok {
		return v
	}
	return ""
}

// intField reads engine_exit, which arrives as a json.Number because the whole stream is decoded
// with UseNumber. A missing or unparseable value reads as -1, which no real exit code can be, so a
// consumer cannot mistake it for a clean 0.
func intField(e events.Event, name string) int {
	type int64er interface{ Int64() (int64, error) }
	if n, ok := e.Payload[name].(int64er); ok {
		if v, err := n.Int64(); err == nil {
			return int(v)
		}
	}
	return -1
}

func quote(s string) string {
	if s == "" {
		return "an unnamed command"
	}
	return fmt.Sprintf("%q", s)
}
