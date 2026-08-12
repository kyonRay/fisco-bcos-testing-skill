// Package exitcode holds the CLI's entire exit-code vocabulary. Six values, no more: CI systems
// branch on these numbers, so a seventh silently changes the meaning of every pipeline that
// already treats "not 0 and not 10" as "the test machine is broken".
package exitcode

import "github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"

type Code int

const (
	OK       Code = 0   // clean sweep
	GateFail Code = 10  // an oracle tripped, or an active scenario/case judged fail
	Config   Code = 20  // bad configuration or usage
	Infra    Code = 30  // dependency missing, cluster/RPC unreachable
	Host     Code = 40  // fbt's own bug: event parse failure, protocol mismatch
	Canceled Code = 130 // SIGINT/SIGTERM. Deliberately NOT Host: ^C is not a bug.
)

func (c Code) Int() int { return int(c) }

func FromClass(c fbterr.Class) Code {
	switch c {
	case fbterr.ClassConfig:
		return Config
	case fbterr.ClassInfra:
		return Infra
	default:
		return Host
	}
}

// FromError maps any error to a code. An unclassified error is a host bug by construction: every
// error fbt raises deliberately carries a class, so an unclassified one escaped from a place that
// forgot to say what kind of failure it was.
func FromError(err error) Code {
	if err == nil {
		return OK
	}
	if c, ok := fbterr.ClassOf(err); ok {
		return FromClass(c)
	}
	return Host
}

// FromOutcome maps a command_finished event's authoritative outcome to a code. spec §8 puts the
// classification in the terminating event on purpose: the host must not infer the result from
// whichever diagnostic `error` events happened to precede it.
func FromOutcome(outcome string) Code {
	switch outcome {
	case "pass":
		return OK
	case "gate_fail":
		return GateFail
	case "config_error":
		return Config
	case "infra_error":
		return Infra
	case "engine_error":
		return Host
	default:
		// An outcome this host does not recognize means the engine speaks a contract we do not.
		return Host
	}
}
