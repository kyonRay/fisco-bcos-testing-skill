package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"path/filepath"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/report"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/workspace"
)

func init() { commands["report"] = reportCommand }

// reportCommand renders what a finished run did.
//
// It exits 0 whatever the run's own verdict was. The run already returned its code; a reporter that
// re-returned it would make `fbt report` on a failed round look like a failed report, and a CI step
// that renders the account of a failure would then fail for having rendered it.
func reportCommand(_ context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("report", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var runID string
	var list bool
	fs.StringVar(&runID, "run-id", "", "which run to report on (default: the most recent)")
	fs.BoolVar(&list, "list", false, "list the runs that have a transcript, newest first")
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
	runsDir := filepath.Join(rt.Paths.State, "runs")

	ids, err := report.Runs(runsDir)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if list {
		if err := render(stdout, o.Output, map[string]interface{}{"runs": ids}, func(w io.Writer) {
			if len(ids) == 0 {
				fmt.Fprintln(w, "no runs have been recorded yet")
				return
			}
			for _, id := range ids {
				fmt.Fprintln(w, id)
			}
		}); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		return exitcode.OK
	}

	if runID == "" {
		if len(ids) == 0 {
			return emitError(stdout, stderr, o.Output,
				fbterr.Configf("no runs have been recorded under %s yet", runsDir))
		}
		runID = ids[0] // ids sort newest-first
	}
	ws, err := workspace.Layout(rt.Paths.State, runID)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rep, err := report.Load(runID, ws.Root, ws.Events, ws.Failures)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	if err := render(stdout, o.Output, rep, func(w io.Writer) { writeReportHuman(w, rep) }); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

func writeReportHuman(w io.Writer, r report.Report) {
	fmt.Fprintf(w, "run %s", r.RunID)
	if r.Command != "" {
		fmt.Fprintf(w, "  (%s)", r.Command)
	}
	if r.Profile != "" {
		fmt.Fprintf(w, "  profile %s", r.Profile)
	}
	fmt.Fprintf(w, "\n%s\n", r.Workspace)
	if r.Started != "" {
		fmt.Fprintf(w, "started  %s\n", r.Started)
	}
	if r.Finished != "" {
		fmt.Fprintf(w, "finished %s  exit %d\n", r.Finished, r.Exit)
	}
	// A transcript with no terminator means the process was killed or the machine went down.
	// Presenting a truncated matrix as a complete one is the one thing a report must not do.
	if r.Partial {
		fmt.Fprintf(w, "INCOMPLETE: this run has no run_finished event -- it was killed, or the "+
			"machine went down. What follows is only what it managed to record.\n")
	}

	if len(r.Matrix) == 0 {
		fmt.Fprintf(w, "\nnothing was recorded: the run ended before any stage reported\n")
	} else {
		fmt.Fprintf(w, "\n%-9s %-22s %-16s %s\n", "KIND", "STAGE", "PHASE", "RESULT")
		for _, c := range r.Matrix {
			fmt.Fprintf(w, "%-9s %-22s %-16s %s", c.Kind, c.Stage, c.Phase, c.Result)
			if c.Reason != "" {
				fmt.Fprintf(w, "  (%s)", c.Reason)
			}
			fmt.Fprintln(w)
		}
	}

	if len(r.Defects) == 0 {
		fmt.Fprintf(w, "\nno defects recorded\n")
		return
	}
	fmt.Fprintf(w, "\n%d defect(s), %d not yet reported anywhere:\n", len(r.Defects), r.Unreported)
	for _, d := range r.Defects {
		mark := "NEW"
		if d.Reported {
			mark = "sent"
		}
		fmt.Fprintf(w, "  [%s] %s/%s %s\n      %s\n      repro:    %s\n      evidence: %s\n",
			mark, d.Scenario, d.Oracle, d.Severity, d.Desc, d.Repro, d.Evidence)
	}
	if r.Unreported > 0 {
		// Named explicitly because the sync is a separate, outward-facing action: it publishes to a
		// shared ledger, and nothing here does it on the operator's behalf.
		fmt.Fprintf(w, "\n  push them to the defect ledger with:\n"+
			"    scripts/report_defects.sh %s --dry-run   # preview first\n", r.Workspace+"/cluster")
	}
}
