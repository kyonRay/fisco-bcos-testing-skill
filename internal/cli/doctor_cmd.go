package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/doctor"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func init() { commands["doctor"] = doctorCommand }

// doctorCommand reports what one command needs and whether this machine has it.
//
// It exits with the same code the checked command would have exited with, so `fbt doctor` in a CI
// preflight step fails the build for the same reason and with the same number as the real run --
// a doctor that always exits 0 tells CI nothing.
func doctorCommand(_ context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var command, scenarios, profileSpec string
	fs.StringVar(&command, "command", "gate", "which command's dependencies to check")
	fs.StringVar(&scenarios, "scenarios", "", "comma-separated scenario families (gate only)")
	fs.StringVar(&profileSpec, "p", "", "profile name or path")
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	plan, err := doctor.Plan(command, splitList(scenarios))
	if err != nil {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("%v; known commands: %s", err, strings.Join(doctor.Commands(), ", ")))
	}
	rt, err := newRuntime(o, profileSpec, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	report, checkErr := doctor.Check(plan, rt.Values, doctor.OSProbe{})
	if renderErr := render(stdout, o.Output, report, func(w io.Writer) {
		if len(report.Deps) == 0 {
			fmt.Fprintf(w, "%s needs nothing checked.\n", command)
			return
		}
		for _, d := range report.Deps {
			mark := "ok"
			if !d.Present {
				mark = "MISSING"
			}
			fmt.Fprintf(w, "%-8s %-14s %s\n", mark, d.Name, d.Detail)
		}
	}); renderErr != nil {
		return emitError(stdout, stderr, o.Output, renderErr)
	}
	if checkErr != nil {
		// The report has already been printed, so the envelope would repeat it in machine mode.
		// Human mode still needs the summary line on stderr.
		if o.Output == OutputHuman {
			fmt.Fprintf(stderr, "fbt: %v\n", checkErr)
		}
		return exitcode.FromError(checkErr)
	}
	return exitcode.OK
}

// splitList parses a comma-separated flag, dropping empties so `--scenarios ut,` is not read as a
// request for a scenario with no name.
func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
