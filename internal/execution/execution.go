// Package execution is the layer between the process runner and the commands.
//
// It exists because "run a script" and "judge a gate round" are separated by six steps that every
// chain-touching command would otherwise reimplement, each slightly differently: check the engine
// manifest BEFORE anything is started, launch under a deadline and a process group, normalize the
// fd 3 stream into the run's single sequence, follow the command_started/command_finished state
// machine, turn all of that into one exit code, and fold that code into the run's aggregate.
//
// Nothing here touches a chain itself. It is the plumbing every chain-touching command shares.
package execution

import (
	"context"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/engine"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/events"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/runner"
)

// Command is one engine command to launch.
type Command struct {
	// Script is a file name inside the engine's scripts directory, e.g. "gate.sh". It is a name,
	// not a path: a caller that could pass an absolute path could point fbt at any executable on
	// the machine and still get the engine's process group, environment and event handling.
	Script string
	Args   []string

	// Requires are engine.json capabilities this command needs. They are checked before the
	// process starts, because discovering halfway through that the engine cannot do what was asked
	// would strand a live cluster (spec §5).
	Requires []string

	// Config is the canonical key/value set for this command, translated to the engine's legacy
	// environment names by the runner.
	Config map[string]string

	Timeout time.Duration
}

// Executor holds everything shared by every command in one run.
type Executor struct {
	Scripts  string          // the engine's scripts directory
	RepoRoot string          // the engine's working directory (spec §7.3)
	Manifest engine.Manifest // already validated by engine.Manifest.Check

	// Norm and Sink are the run's single event pipeline. Every engine subprocess and the host's own
	// run_started/run_finished share them, which is what makes seq a global ordering.
	Norm *events.Normalizer
	Sink func(events.Event)

	// Agg accumulates the run's exit code across every command.
	Agg *exitcode.Aggregator

	// Log receives the engine's stdout and stderr as they arrive, for a human watching the run.
	// Nil discards them; Result still carries the tail either way.
	Log io.Writer

	KillGrace time.Duration
}

// Run executes one engine command and returns its verdict. It reports failures through Result
// rather than a bare error, because a caller has to distinguish a chain that failed the gate from
// a host that could not run the command at all -- and both are ordinary outcomes of calling this.
func (e *Executor) Run(ctx context.Context, c Command) Result {
	if err := e.precheck(c); err != nil {
		return e.record(failed(err))
	}

	root := c.Script
	tr := newTracker(root)
	var streamErr error

	res, err := runner.Run(ctx, runner.Spec{
		Script:    filepath.Join(e.Scripts, c.Script),
		Args:      c.Args,
		Dir:       e.RepoRoot,
		Config:    c.Config,
		Stdout:    e.Log,
		Stderr:    e.Log,
		Timeout:   c.Timeout,
		KillGrace: e.KillGrace,
		Events: func(line []byte) {
			// One line at a time rather than handing Read the whole pipe: the tracker has to see
			// events in delivery order, and a breach on line 3 must not stop lines 4..n from
			// reaching the --output jsonl consumer.
			if streamErr != nil {
				return // the stream is already known broken; further parses add nothing
			}
			if err := e.Norm.Read(root, strings.NewReader(string(line)+"\n"), func(ev events.Event) {
				tr.Observe(ev)
				if e.Sink != nil {
					e.Sink(ev)
				}
			}); err != nil {
				streamErr = err
			}
		},
	})
	if err != nil {
		// The command never started: a bad config value, a missing or non-executable script, a
		// working directory that is not there. All of those are already classified.
		return e.record(failed(err))
	}

	return e.record(withAbandoned(classify(root, res, tr, streamErr), tr.abandoned))
}

// precheck runs every gate that must close BEFORE a process exists.
func (e *Executor) precheck(c Command) error {
	if c.Script == "" {
		return fbterr.Hostf("no engine script named")
	}
	// A path here would let the caller escape the engine's script directory, which is the only
	// place the manifest makes any promise about.
	if c.Script != filepath.Base(c.Script) {
		return fbterr.Hostf("engine command %q must be a bare script name, not a path", c.Script)
	}
	for _, want := range c.Requires {
		if !e.Manifest.Has(want) {
			return fbterr.Hostf("this fbt needs the %q capability but the installed engine does "+
				"not declare it; the engine and fbt are from different releases", want)
		}
	}
	return nil
}

// failed wraps a pre-start error, which by construction never reached the engine and so has no
// outcome and no process to report.
func failed(err error) Result {
	return Result{
		Code:       exitcode.FromError(err),
		EngineExit: -1,
		Reason:     err.Error(),
		Err:        err,
	}
}

// record folds one command's verdict into the run's aggregate.
func (e *Executor) record(r Result) Result {
	if e.Agg == nil {
		return r
	}
	// MarkCanceled and MarkTimeout carry semantics Add cannot: cancellation outranks every
	// aggregate, and a recorded timeout suppresses the signal death that the host itself caused.
	if r.Runner.Canceled {
		e.Agg.MarkCanceled()
	}
	if r.Runner.TimedOut {
		e.Agg.MarkTimeout()
	}
	if r.Runner.Signaled {
		// Self-suppressing after MarkTimeout, which is the whole reason it is a separate entry
		// point. classify already reached the same conclusion; this is the aggregator's own record
		// of how the process died, and the two must not be allowed to disagree.
		e.Agg.AddSignalDeath()
	}
	e.Agg.Add(r.Code)
	return r
}

// Start and Finish emit the host's own bracketing events (spec §8: run_started and run_finished are
// the host's, because one `gate run` orchestrates gate.sh plus many run_case.sh invocations and no
// single engine process can bracket them).
func (e *Executor) Start(runID string, fields map[string]interface{}) {
	if fields == nil {
		fields = map[string]interface{}{}
	}
	fields["run_id"] = runID
	e.Norm.Emit("run_started", fields, e.Sink)
}

func (e *Executor) Finish(code exitcode.Code) {
	e.Norm.Emit("run_finished", map[string]interface{}{"exit": code.Int()}, e.Sink)
}
