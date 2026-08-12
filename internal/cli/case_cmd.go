package cli

import (
	"context"
	"flag"
	"fmt"
	"io"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/cases"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/execution"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func init() { commands["case"] = caseCommand }

func caseCommand(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("case needs a subcommand: list or run"))
	}
	switch args[0] {
	case "list":
		return caseList(o, args[1:], stdout, stderr)
	case "run":
		return caseRun(ctx, o, args[1:], stdout, stderr)
	}
	return emitError(stdout, stderr, o.Output,
		fbterr.Configf("unknown subcommand %q; case takes list or run", args[0]))
}

type caseListDoc struct {
	Cases   []cases.Case `json:"cases"`
	Swept   int          `json:"swept"`
	Pending int          `json:"pending"`
}

// caseList shows every fixture and, crucially, which ones the gate will actually run.
//
// The pending count is on the summary line on purpose: a pending fixture is a KNOWN unfixed
// defect that no gate round will ever report, so it is the number most likely to be forgotten.
func caseList(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("case list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, "", stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	all, err := rt.Cases.List()
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	doc := caseListDoc{Cases: all, Swept: len(cases.Sweep(all))}
	for _, c := range all {
		if c.Status == cases.StatusPending {
			doc.Pending++
		}
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		for _, c := range all {
			fmt.Fprintf(w, "%-24s %-8s %-8s %-20s %s\n",
				c.Name, c.Status, c.Expect, c.Profile, c.Source)
		}
		fmt.Fprintf(w, "\n%d case(s): %d swept by the gate, %d pending (a known defect nobody's "+
			"round will report)\n", len(all), doc.Swept, doc.Pending)
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

type caseRunDoc struct {
	Exit    int    `json:"exit"`
	RunID   string `json:"run_id"`
	Case    string `json:"case"`
	Status  string `json:"status"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
}

// caseRun replays one fixture and returns its REAL result, whatever its status says.
//
// status decides gate membership, not truth (spec §6.4). Replaying a pending case is how you find
// out whether the defect is finally fixed, so suppressing its result here would remove the only
// way to answer that question.
func caseRun(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("case run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var dryRun bool
	fs.BoolVar(&dryRun, "dry-run", false, "print the resolved plan, touch no chain")
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if fs.NArg() != 1 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("case run takes exactly one case name or path"))
	}
	rt, err := newRuntime(o, "", stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	c, err := rt.Cases.Find(fs.Arg(0))
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	cmdArgs := []string{c.Path}
	if dryRun {
		cmdArgs = append(cmdArgs, "--dry-run")
	} else {
		// A dry run builds nothing, so giving it a workspace would leave an empty run directory
		// behind for every plan someone printed.
		if err := rt.begin(map[string]interface{}{"case": c.Name}); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		cmdArgs = append(cmdArgs, "-o", rt.Workspace.Cluster)
	}

	res := rt.Exec.Run(ctx, execution.Command{
		Script:   "run_case.sh",
		Args:     cmdArgs,
		Requires: []string{"case"},
		Config:   rt.engineConfig(),
		Timeout:  rt.timeout(),
	})
	code := rt.Agg.Result()
	rt.Exec.Finish(code)

	doc := caseRunDoc{
		Exit: code.Int(), RunID: rt.Norm.RunID, Case: c.Name,
		Status: string(c.Status), Outcome: res.Outcome, Reason: res.Reason,
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		fmt.Fprintf(w, "case %s (%s): %s\n", c.Name, c.Status, verdictWord(res.Outcome, code))
		if res.Reason != "" {
			fmt.Fprintf(w, "  %s\n", res.Reason)
		}
	}); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}
	return code
}

func verdictWord(outcome string, code exitcode.Code) string {
	if outcome != "" {
		return outcome
	}
	if code == exitcode.OK {
		return "pass"
	}
	return "no verdict"
}
