package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"io"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
)

// probe is a command that exists only in this test file. Registering a placeholder in the real
// table to "test dispatch" would ship a command that answers nothing.
type probe struct {
	got    GlobalOptions
	args   []string
	called bool
	ret    exitcode.Code
}

func (p *probe) cmd() Command {
	return func(_ context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
		p.got, p.args, p.called = o, args, true
		return p.ret
	}
}

// probeAcceptingGlobals re-registers the global flags on its own flag set, which is how the real
// subcommands let `fbt config show --output json` work with the flag after the command name.
func probeAcceptingGlobals(p *probe) Command {
	return func(_ context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
		fs := flag.NewFlagSet("probe", flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		finish := RegisterGlobalFlags(fs, &o)
		if err := fs.Parse(args); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		if err := finish(); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
		p.got, p.args, p.called = o, fs.Args(), true
		return p.ret
	}
}

func run(t *testing.T, table map[string]Command, argv ...string) (exitcode.Code, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := dispatch(context.Background(), table, argv, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestEveryGlobalFlagReachesTheCommand(t *testing.T) {
	p := &probe{}
	code, _, _ := run(t, map[string]Command{"probe": p.cmd()},
		"--config", "/c.yaml", "--engine-dir", "/opt/fbt", "--state-dir", "/s",
		"--output", "json", "--no-color", "--verbose", "probe", "extra", "--after")
	if code != exitcode.OK || !p.called {
		t.Fatalf("code=%v called=%v", code, p.called)
	}
	want := GlobalOptions{ConfigPath: "/c.yaml", EngineDir: "/opt/fbt", StateDir: "/s",
		Output: OutputJSON, NoColor: true, Verbose: true}
	if p.got != want {
		t.Errorf("GlobalOptions = %+v, want %+v", p.got, want)
	}
	// Arguments after the command name belong to the command, untouched.
	if len(p.args) != 2 || p.args[0] != "extra" || p.args[1] != "--after" {
		t.Errorf("args = %q, want [extra --after]", p.args)
	}
}

// Go's flag package has no alias mechanism; -v and --verbose must be bound to the same field
// separately, and forgetting one is invisible until a user types the other.
func TestShortAndLongVerboseBothSetTheSameField(t *testing.T) {
	for _, f := range []string{"-v", "--verbose"} {
		p := &probe{}
		if _, _, _ = run(t, map[string]Command{"probe": p.cmd()}, f, "probe"); !p.got.Verbose {
			t.Errorf("%s did not set Verbose", f)
		}
	}
}

// spec §4: --ai takes on|off and nothing else. "banana" must not be waved through as off just
// because it is not "on".
func TestAIFlagIsStrict(t *testing.T) {
	p := &probe{}
	table := map[string]Command{"probe": p.cmd()}

	if code, _, _ := run(t, table, "--ai", "off", "probe"); code != exitcode.OK {
		t.Errorf("--ai off should be accepted, got %v", code)
	}
	for _, v := range []string{"on", "banana", "", "ON"} {
		p.called = false
		code, _, _ := run(t, table, "--ai", v, "probe")
		if code != exitcode.Config {
			t.Errorf("--ai %q = %v, want 20", v, code)
		}
		if p.called {
			t.Errorf("--ai %q reached the command", v)
		}
	}
}

func TestOutputModeIsValidated(t *testing.T) {
	p := &probe{}
	table := map[string]Command{"probe": p.cmd()}
	for mode, want := range map[string]OutputMode{
		"human": OutputHuman, "json": OutputJSON, "jsonl": OutputJSONL,
	} {
		if _, _, _ = run(t, table, "--output", mode, "probe"); p.got.Output != want {
			t.Errorf("--output %s = %v, want %v", mode, p.got.Output, want)
		}
	}
	if code, _, _ := run(t, table, "--output", "banana", "probe"); code != exitcode.Config {
		t.Errorf("--output banana = %v, want 20", code)
	}
}

func TestHumanIsTheDefaultOutputMode(t *testing.T) {
	p := &probe{}
	if _, _, _ = run(t, map[string]Command{"probe": p.cmd()}, "probe"); p.got.Output != OutputHuman {
		t.Errorf("default output = %v, want human", p.got.Output)
	}
}

func TestCommandExitCodeIsPropagated(t *testing.T) {
	p := &probe{ret: exitcode.GateFail}
	if code, _, _ := run(t, map[string]Command{"probe": p.cmd()}, "probe"); code != exitcode.GateFail {
		t.Errorf("code = %v, want the command's own 10", code)
	}
}

func TestUnknownCommandAndNoCommandAreUsageErrors(t *testing.T) {
	table := map[string]Command{"probe": (&probe{}).cmd()}
	code, _, errOut := run(t, table, "nonesuch")
	if code != exitcode.Config {
		t.Errorf("unknown command = %v, want 20", code)
	}
	if !strings.Contains(errOut, "nonesuch") || !strings.Contains(errOut, "probe") {
		t.Errorf("the error should name the bad command and list the real ones, got %q", errOut)
	}
	if code, _, _ := run(t, table); code != exitcode.Config {
		t.Errorf("no command = %v, want 20", code)
	}
}

func TestUnknownGlobalFlagIsAUsageErrorAndNeverReachesTheCommand(t *testing.T) {
	p := &probe{}
	code, _, errOut := run(t, map[string]Command{"probe": p.cmd()}, "--nope", "probe")
	if code != exitcode.Config || p.called {
		t.Errorf("code=%v called=%v, want 20 and not called", code, p.called)
	}
	if errOut == "" {
		t.Error("a flag error must still say something")
	}
}

func TestHelpIsNotAnError(t *testing.T) {
	code, out, _ := run(t, map[string]Command{"probe": (&probe{}).cmd()}, "--help")
	if code != exitcode.OK {
		t.Errorf("--help = %v, want 0", code)
	}
	if !strings.Contains(out, "probe") {
		t.Errorf("usage should list the commands, got %q", out)
	}
}

func TestVersionWorksWithoutACommand(t *testing.T) {
	code, out, _ := run(t, map[string]Command{}, "--version")
	if code != exitcode.OK || !strings.Contains(out, Version) {
		t.Errorf("code=%v out=%q, want 0 and the version string", code, out)
	}

	code, out, _ = run(t, map[string]Command{}, "--output", "json", "--version")
	if code != exitcode.OK {
		t.Fatalf("code = %v", code)
	}
	var doc map[string]interface{}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("--output json --version is not JSON: %v (%q)", err, out)
	}
	if doc["version"] != Version {
		t.Errorf("doc = %+v, want version %q", doc, Version)
	}
}

// A global flag after the command name is the shape users actually type
// (`fbt config show --output json`), so the subcommands re-register the same flags.
func TestGlobalFlagsAlsoWorkAfterTheCommandName(t *testing.T) {
	p := &probe{}
	code, _, _ := run(t, map[string]Command{"probe": probeAcceptingGlobals(p)},
		"probe", "--output", "jsonl", "--config", "/late.yaml", "rest")
	if code != exitcode.OK {
		t.Fatalf("code = %v", code)
	}
	if p.got.Output != OutputJSONL || p.got.ConfigPath != "/late.yaml" {
		t.Errorf("got %+v, want the late flags applied", p.got)
	}
	if len(p.args) != 1 || p.args[0] != "rest" {
		t.Errorf("args = %q, want [rest]", p.args)
	}
}

// spec §11: every failure path must be structured, without exception. A global flag error is the
// easiest one to miss, because it happens before the flag package has parsed --output -- and a
// machine consumer that asked for json must not get prose on stderr instead.
func TestGlobalFlagErrorsRespectTheRequestedOutputShape(t *testing.T) {
	table := map[string]Command{"probe": (&probe{}).cmd()}
	for _, argv := range [][]string{
		{"--output", "json", "--nonesuch", "probe"},
		{"--output=json", "--nonesuch", "probe"},
		{"-output", "json", "--nonesuch", "probe"},
		{"--output", "json", "--ai", "banana", "probe"},
	} {
		code, out, errOut := run(t, table, argv...)
		if code != exitcode.Config {
			t.Errorf("%v: code = %v, want 20", argv, code)
		}
		if errOut != "" {
			t.Errorf("%v: stderr must stay clean in json mode, got %q", argv, errOut)
		}
		var doc map[string]interface{}
		if err := json.Unmarshal([]byte(out), &doc); err != nil {
			t.Errorf("%v: stdout is not a JSON document: %v (%q)", argv, err, out)
			continue
		}
		if doc["exit"] != float64(20) || doc["class"] != "config" {
			t.Errorf("%v: doc = %+v", argv, doc)
		}
	}

	// A bad --output value has no valid shape to honour, so it reports in human form.
	code, _, errOut := run(t, table, "--output", "banana", "--nonesuch", "probe")
	if code != exitcode.Config || errOut == "" {
		t.Errorf("code=%v stderr=%q; a bad --output must still say something", code, errOut)
	}

	// The pre-scan must stop at the command name: a subcommand's own --output is the subcommand's
	// business, and must not silently reshape a global parse error.
	if m, err := preScanOutputMode([]string{"probe", "--output", "json"}); err != nil || m != OutputHuman {
		t.Errorf("preScan leaked past the command name: %v, %v", m, err)
	}
}

// spec §9: 130 outranks every aggregate result. A command that finished its work before noticing
// the interrupt must not report that work as a clean result -- the user stopped the run, so what
// it had concluded is no longer an answer about the chain.
func TestAnInterruptedRunExits130WhateverTheCommandReturned(t *testing.T) {
	for _, ret := range []exitcode.Code{exitcode.OK, exitcode.GateFail, exitcode.Host} {
		ctx, cancel := context.WithCancel(context.Background())
		table := map[string]Command{
			"probe": func(c context.Context, _ GlobalOptions, _ []string, _, _ io.Writer) exitcode.Code {
				cancel() // the interrupt lands while the command is running
				return ret
			},
		}
		var out, errOut bytes.Buffer
		if code := dispatch(ctx, table, []string{"probe"}, &out, &errOut); code != exitcode.Canceled {
			t.Errorf("command returned %v: dispatch exited %v, want 130", ret, code)
		}
	}
}

// ...but an uninterrupted run keeps its own verdict. Without this the check above could be
// satisfied by always returning 130.
func TestAnUninterruptedRunKeepsItsVerdict(t *testing.T) {
	table := map[string]Command{
		"probe": func(context.Context, GlobalOptions, []string, io.Writer, io.Writer) exitcode.Code {
			return exitcode.GateFail
		},
	}
	var out, errOut bytes.Buffer
	if code := dispatch(context.Background(), table, []string{"probe"}, &out, &errOut); code != exitcode.GateFail {
		t.Errorf("code = %v, want 10", code)
	}
}
