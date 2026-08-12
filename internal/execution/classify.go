package execution

import (
	"fmt"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/runner"
)

// Result is one engine command's verdict, already reduced to the exit-code vocabulary.
type Result struct {
	Code       exitcode.Code
	Outcome    string // the engine's own word; empty when it never terminated
	EngineExit int
	Reason     string // one sentence; empty on a clean pass
	// Err carries Reason as a classified error for the §11 failure envelope. It is nil for a pass
	// AND for a gate failure: a chain that failed the gate is a RESULT, not an fbt error, and
	// dressing it as one would put it in the same envelope as "your config is broken".
	Err    error
	Runner runner.Result
}

// classify turns "what the process did" plus "what the protocol said" into one code.
//
// The order of the checks is the contract, not a style choice -- see the comments on each step.
func classify(root string, res runner.Result, t *tracker, streamErr error) Result {
	out := Result{Runner: res, EngineExit: -1}
	if t.term != nil {
		out.Outcome, out.EngineExit = t.term.Outcome, t.term.EngineExit
	}

	// 1. Cancellation outranks every other verdict (spec §9): the user stopped the run, so whatever
	// the partial results were saying is no longer a judgment about the chain.
	if res.Canceled {
		out.Code = exitcode.Canceled
		out.Reason = fmt.Sprintf("%s was cancelled", root)
		return out
	}

	// 2. The timeout verdict is made HERE and is not revisited below. The host TERMs and KILLs the
	// process group on deadline, and that death would otherwise be re-read as "the engine died
	// unexpectedly" (40) when the real finding is a chain that stopped answering (30).
	if res.TimedOut {
		out.Code = exitcode.Infra
		out.Reason = fmt.Sprintf("%s exceeded its deadline and was terminated", root)
		return out
	}

	// 3. Only now can a broken event stream be blamed on the engine. Ordering this above the two
	// checks would misfile the host's own kill: TERMing the engine mid-write leaves a truncated
	// final line on fd 3, the decoder rejects it, and a chain that merely hung would be reported as
	// an fbt bug.
	if streamErr != nil {
		return hostFail(out, streamErr.Error())
	}
	if t.breach != nil {
		return hostFail(out, t.breach.Error())
	}

	// 4. No terminator. Spec §8 requires exactly one per launched command, and §9 reads its absence
	// as the engine having died unexpectedly.
	if t.term == nil {
		switch {
		case res.Signaled:
			return hostFail(out, fmt.Sprintf("%s was terminated by signal %d without emitting "+
				"command_finished", root, int(res.Signal)))
		default:
			return hostFail(out, fmt.Sprintf("%s exited %d without emitting command_finished; "+
				"every engine command must arm its EXIT trap before parsing arguments",
				root, res.ExitCode))
		}
	}

	// 5. The terminator's outcome is authoritative -- with one guard.
	//
	// "pass" alongside a non-zero process exit is a contradiction, and it is the specific
	// contradiction this harness exists to catch: an engine that reports success while actually
	// failing is a false green, and trusting the word over the exit code would ship it. The signal
	// path is excluded because event_lib reports 128+n there deliberately.
	if t.term.Outcome == "pass" && res.ExitCode != 0 {
		return hostFail(out, fmt.Sprintf("%s reported outcome=pass but exited %d; the engine's "+
			"verdict contradicts its own exit status", root, res.ExitCode))
	}

	out.Code = exitcode.FromOutcome(t.term.Outcome)
	switch out.Code {
	case exitcode.OK:
		return out
	case exitcode.Host:
		if !knownOutcome(t.term.Outcome) {
			return hostFail(out, fmt.Sprintf("%s reported an outcome this fbt does not understand "+
				"(%s); the engine speaks a contract this build does not", root, quote(t.term.Outcome)))
		}
		return hostFail(out, fmt.Sprintf("%s failed with an engine fault (exit %d)",
			root, t.term.EngineExit))
	case exitcode.GateFail:
		// No Err: a gate failure is the answer the gate was asked for.
		out.Reason = fmt.Sprintf("%s judged the chain failed the gate", root)
		return out
	default:
		out.Reason = fmt.Sprintf("%s reported %s (exit %d)", root, t.term.Outcome, t.term.EngineExit)
		out.Err = fbterr.Wrap(fmt.Errorf("%s", out.Reason), classOf(out.Code))
		return out
	}
}

func hostFail(out Result, reason string) Result {
	out.Code = exitcode.Host
	out.Reason = reason
	out.Err = fbterr.Hostf("%s", reason)
	return out
}

func classOf(c exitcode.Code) fbterr.Class {
	switch c {
	case exitcode.Config:
		return fbterr.ClassConfig
	case exitcode.Infra:
		return fbterr.ClassInfra
	}
	return fbterr.ClassHost
}

func knownOutcome(s string) bool {
	switch s {
	case "pass", "gate_fail", "config_error", "infra_error", "engine_error":
		return true
	}
	return false
}

// withAbandoned appends the names of engine subprocesses that never terminated. They do not change
// the verdict -- the launched command's own outcome is authoritative -- but a nested script that
// died hard is the kind of thing that explains an otherwise puzzling failure.
func withAbandoned(r Result, abandoned []string) Result {
	if len(abandoned) == 0 || r.Code == exitcode.OK {
		return r
	}
	r.Reason += fmt.Sprintf(" (nested engine commands that never finished: %s)",
		strings.Join(abandoned, ", "))
	if r.Err != nil {
		r.Err = fbterr.Wrap(fmt.Errorf("%s", r.Reason), classOf(r.Code))
	}
	return r
}
