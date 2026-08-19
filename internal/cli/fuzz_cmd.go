package cli

import (
	"context"
	"flag"
	"fmt"
	"io"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/doctor"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/execution"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
)

func init() { commands["fuzz"] = fuzzCommand }

type runDoc struct {
	Exit    int    `json:"exit"`
	RunID   string `json:"run_id"`
	Command string `json:"command"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
}

func fuzzCommand(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 || args[0] != "run" {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("fuzz takes one subcommand: run"))
	}
	fs := flag.NewFlagSet("fuzz run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var seed, iters, batch int
	var attach, transport, strategy, restartCmd string
	fs.IntVar(&seed, "seed", 0, "random seed (0 lets the engine choose)")
	fs.IntVar(&iters, "iters", 0, "iterations (0 uses the engine's default)")
	fs.IntVar(&batch, "batch", 0, "batch size (0 uses the engine's default)")
	fs.StringVar(&attach, "attach", "", "run against an already-registered cluster's run id")
	fs.StringVar(&transport, "transport", "", "which RPC surface to fuzz: bcos|web3|web3method")
	fs.StringVar(&strategy, "strategy", "", "mutation strategy: struct|bytes|both")
	fs.StringVar(&restartCmd, "restart-cmd", "",
		"command the driver runs to bring a crashed node back, so a run survives the crash it found")
	if err := fs.Parse(args[1:]); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, "", stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	// fuzz has its own dependency matrix: it attaches to a cluster somebody else built, so
	// demanding the checkout and console here would refuse a run that needs neither.
	plan, err := doctor.Plan("fuzz", nil)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if _, err := doctor.CheckIn(rt.Exec.RepoRoot, plan, rt.Values, doctor.OSProbe{}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	cfg := rt.engineConfig()
	// Flags are the highest configuration layer, so they overwrite whatever the file said.
	for k, v := range map[string]int{"fuzz.seed": seed, "fuzz.iters": iters, "fuzz.batch": batch} {
		if v > 0 {
			cfg[k] = fmt.Sprint(v)
		}
	}
	// Validated through the key registry rather than against a list written out here. The registry
	// already owns these vocabularies (fuzz.transport is bcos|web3|web3method, fuzz.strategy is
	// struct|bytes|both); a second copy in the flag layer is one that drifts. Injecting straight
	// into cfg happens AFTER the merge, so it skips the validation every other layer gets -- which
	// would hand the engine RG_FUZZ_TRANSPORT=banana and let it fail somewhere less obvious.
	for _, kv := range []struct{ key, value string }{
		{"fuzz.transport", transport}, {"fuzz.strategy", strategy}, {"fuzz.restart_cmd", restartCmd},
	} {
		if kv.value == "" {
			continue
		}
		if err := keys.Validate(kv.key, kv.value); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		cfg[kv.key] = kv.value
	}

	// A fuzz run writes the cases it distils, so it needs a workspace even when it attaches to
	// somebody else's cluster.
	if err := rt.begin(map[string]interface{}{"command": "fuzz"}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	fuzzArgs := []string{"-o", rt.Workspace.Cluster}
	if attach != "" {
		entry, err := rt.Registry.Resolve(attach, "")
		if err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		// Attaching means using the OTHER run's cluster directory. Its reservation is untouched:
		// that cluster belongs to the run that built it, and releasing it here would let a third
		// run claim ports this one is actively fuzzing.
		fuzzArgs = []string{"-o", entry.Workspace}
	}

	res := rt.Exec.Run(ctx, execution.Command{
		Script:   "fuzz_bcos.sh",
		Args:     fuzzArgs,
		Requires: []string{"fuzz"},
		Config:   cfg,
		Timeout:  rt.timeout(),
	})
	return finishRun(rt, res, "fuzz", stdout, stderr, o)
}

// upgradeRun drives the T0-T8 version-upgrade timeline. Reached as `fbt gate upgrade`.
//
// It is not a gate SCENARIO because gate.sh's dispatch loop calls every registered scenario with
// no arguments and this one needs four -- which is exactly why gate_upgrade.sh exists as its own
// entry point. It is still a gate subcommand: it judges the same chain and returns the same
// verdict vocabulary.
func upgradeRun(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("gate upgrade", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var profileSpec, oldBin, newBin, targetVer string
	var dryRun bool
	fs.StringVar(&profileSpec, "p", "production-enterprise", "profile name or path")
	fs.StringVar(&oldBin, "old-bin", "", "the binary the chain starts on (the T0 baseline)")
	fs.StringVar(&newBin, "new-bin", "", "the release candidate rolled in during T2-T4")
	fs.StringVar(&targetVer, "target-ver", "", "the compatibility_version the T5 bump moves to")
	fs.BoolVar(&dryRun, "dry-run", false, "print the resolved plan, touch no chain")
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	for _, req := range []struct{ flag, value string }{
		{"--old-bin", oldBin}, {"--new-bin", newBin}, {"--target-ver", targetVer},
	} {
		if req.value == "" {
			return emitError(stdout, stderr, o.Output,
				fbterr.Configf("%s is required for an upgrade run", req.flag))
		}
	}
	rt, err := newRuntime(o, profileSpec, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	upArgs := []string{"-p", rt.ProfilePath, "--old-bin", oldBin, "--new-bin", newBin,
		"--target-ver", targetVer}
	if dryRun {
		upArgs = append(upArgs, "--dry-run")
	} else {
		if err := rt.begin(map[string]interface{}{"command": "upgrade", "target_ver": targetVer}); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		upArgs = append(upArgs, "-o", rt.Workspace.Cluster)
	}

	res := rt.Exec.Run(ctx, execution.Command{
		Script:   "gate_upgrade.sh",
		Args:     upArgs,
		Requires: []string{"upgrade"},
		Config:   rt.engineConfig(),
		Timeout:  rt.timeout(),
	})
	return finishRun(rt, res, "upgrade", stdout, stderr, o)
}

// finishRun closes the run and renders the result. It is shared so the two commands cannot drift
// apart in how they report an outcome.
func finishRun(rt *runtime, res execution.Result, name string, stdout, stderr io.Writer, o GlobalOptions) exitcode.Code {
	code := rt.Agg.Result()
	if rt.Norm.RunID != "" {
		rt.Exec.Finish(code)
	}
	doc := runDoc{
		Exit: code.Int(), RunID: rt.Norm.RunID, Command: name,
		Outcome: verdictWord(res.Outcome, code), Reason: res.Reason,
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		fmt.Fprintf(w, "%s: %s\n", name, doc.Outcome)
		if doc.Reason != "" {
			fmt.Fprintf(w, "  %s\n", doc.Reason)
		}
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return code
}
