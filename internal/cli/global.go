// Package cli holds the command-line surface: global flags, dispatch, and the two output
// functions every command writes through.
package cli

import (
	"flag"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Version is stamped into `fbt --version` and into every machine-readable document that reports
// which fbt produced it.
const Version = "0.1.0-dev"

// GlobalOptions are the settings that apply to every command (spec §6.5).
type GlobalOptions struct {
	ConfigPath string
	EngineDir  string
	StateDir   string
	Output     OutputMode
	Verbose    bool
	NoColor    bool
}

// Command is one subcommand. It receives the already-parsed globals, its own remaining arguments,
// and the two streams -- never os.Stdout directly, so every command is testable in memory.
type Command func(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code

// commands is the real table. Only implemented commands are registered: a placeholder that
// answers nothing would still show up in `fbt --help` and in shell completion, promising a command
// that does not exist. Task 9 registers config and profile.
var commands = map[string]Command{}

// globalFlags holds the flag-shaped values before validation. --output and --ai arrive as strings
// and become typed values only after being checked, so an invalid one is refused instead of
// silently mapping onto a default.
type globalFlags struct {
	opts        *GlobalOptions
	output, ai  string
	showVersion bool
}

// RegisterGlobalFlags binds the global flags onto fs, writing into o, and returns the function
// that validates the string-shaped ones -- call it after fs.Parse. Both Dispatch and each
// subcommand use it, so `fbt --output json config show` and `fbt config show --output json` mean
// the same thing; the second is what users actually type.
//
// The finish step is a returned closure rather than a package-level lookup because a flag set is
// per-invocation state: keeping it in a shared map would make two concurrent commands step on
// each other for no gain.
func RegisterGlobalFlags(fs *flag.FlagSet, o *GlobalOptions) func() error {
	g := &globalFlags{opts: o, output: o.Output.String(), ai: "off"}
	g.bind(fs)
	return g.finish
}

func (g *globalFlags) bind(fs *flag.FlagSet) {
	fs.StringVar(&g.opts.ConfigPath, "config", g.opts.ConfigPath, "path to fbt.yaml")
	fs.StringVar(&g.opts.EngineDir, "engine-dir", g.opts.EngineDir, "installation root (contains libexec/ and share/)")
	fs.StringVar(&g.opts.StateDir, "state-dir", g.opts.StateDir, "state directory (default $XDG_STATE_HOME/fbt)")
	fs.StringVar(&g.output, "output", g.output, "output shape: human, json or jsonl")
	fs.StringVar(&g.ai, "ai", g.ai, "AI assistance: on or off")
	fs.BoolVar(&g.opts.NoColor, "no-color", g.opts.NoColor, "disable coloured output")
	// Go's flag package has no alias mechanism: -v and --verbose must be bound separately to the
	// same field, and forgetting one is invisible until a user types the other.
	fs.BoolVar(&g.opts.Verbose, "verbose", g.opts.Verbose, "verbose output")
	fs.BoolVar(&g.opts.Verbose, "v", g.opts.Verbose, "verbose output (shorthand)")
	fs.BoolVar(&g.showVersion, "version", false, "print the version and exit")
}

func (g *globalFlags) finish() error {
	mode, err := ParseOutputMode(g.output)
	if err != nil {
		return err
	}
	g.opts.Output = mode
	// spec §4: on|off and nothing else. "banana" must not be waved through as off just because it
	// is not "on", and "on" is an explicit 20 rather than a silent no-op.
	switch g.ai {
	case "off":
		return nil
	case "on":
		return fbterr.Configf("--ai on is not implemented in this build")
	default:
		return fbterr.Configf("--ai must be on or off, got %q", g.ai)
	}
}

// Dispatch is the process entry point: it owns the real command table.
func Dispatch(argv []string, stdout, stderr io.Writer) exitcode.Code {
	return dispatch(commands, argv, stdout, stderr)
}

func dispatch(table map[string]Command, argv []string, stdout, stderr io.Writer) exitcode.Code {
	var opts GlobalOptions
	fs := flag.NewFlagSet("fbt", flag.ContinueOnError)
	// The flag package's own messages bypass the output contract, so they are discarded and every
	// failure is re-emitted through emitError.
	fs.SetOutput(io.Discard)
	g := &globalFlags{opts: &opts, output: "human", ai: "off"}
	g.bind(fs)

	// The requested shape has to be known BEFORE parsing can fail, or `fbt --output json
	// --nonesuch` answers a machine consumer with prose on stderr -- the one thing --output json
	// exists to eliminate. A bad --output value is reported in human shape, because at that point
	// no valid shape was requested.
	mode, modeErr := preScanOutputMode(argv)

	if err := fs.Parse(argv); err != nil {
		if err == flag.ErrHelp {
			// --help is a request, not a failure: usage on stdout, exit 0.
			writeUsage(stdout, table)
			return exitcode.OK
		}
		return emitError(stdout, stderr, mode, fbterr.Configf("%v", err))
	}
	if modeErr != nil {
		return emitError(stdout, stderr, OutputHuman, modeErr)
	}
	if err := g.finish(); err != nil {
		return emitError(stdout, stderr, mode, err)
	}

	if g.showVersion {
		doc := map[string]string{"version": Version}
		if err := render(stdout, opts.Output, doc, func(w io.Writer) {
			fmt.Fprintf(w, "fbt %s\n", Version)
		}); err != nil {
			return emitError(stdout, stderr, opts.Output, err)
		}
		return exitcode.OK
	}

	args := fs.Args()
	if len(args) == 0 {
		if opts.Output == OutputHuman {
			writeUsage(stderr, table)
		}
		return emitError(stdout, stderr, opts.Output,
			fbterr.Configf("no command given (try `fbt --help`)"))
	}
	cmd, ok := table[args[0]]
	if !ok {
		return emitError(stdout, stderr, opts.Output,
			fbterr.Configf("unknown command %q; available commands: %s",
				args[0], strings.Join(names(table), ", ")))
	}
	return cmd(opts, args[1:], stdout, stderr)
}

// preScanOutputMode finds --output in a raw argv before the flag package has had a chance to
// reject anything. It accepts both spellings the flag package does (`--output json` and
// `--output=json`, with one or two dashes) and stops at the command name, so a subcommand's own
// arguments cannot change the shape of a global parse error.
func preScanOutputMode(argv []string) (OutputMode, error) {
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		if !strings.HasPrefix(a, "-") {
			break // the command name: global flags are over
		}
		name := strings.TrimLeft(a, "-")
		if eq := strings.IndexByte(name, '='); eq >= 0 {
			if name[:eq] == "output" {
				return ParseOutputMode(name[eq+1:])
			}
			continue
		}
		if name == "output" && i+1 < len(argv) {
			return ParseOutputMode(argv[i+1])
		}
	}
	return OutputHuman, nil
}

func names(table map[string]Command) []string {
	out := make([]string, 0, len(table))
	for k := range table {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func writeUsage(w io.Writer, table map[string]Command) {
	fmt.Fprintf(w, "fbt %s -- FISCO-BCOS release gate\n\nusage: fbt [global flags] <command> [args]\n\n", Version)
	fmt.Fprintf(w, "commands:\n")
	for _, n := range names(table) {
		fmt.Fprintf(w, "  %s\n", n)
	}
	fmt.Fprintf(w, "\nglobal flags:\n")
	fmt.Fprintf(w, "  --config <path>       path to fbt.yaml\n")
	fmt.Fprintf(w, "  --engine-dir <path>   installation root (contains libexec/ and share/)\n")
	fmt.Fprintf(w, "  --state-dir <path>    state directory (default $XDG_STATE_HOME/fbt)\n")
	fmt.Fprintf(w, "  --output <shape>      human (default), json or jsonl\n")
	fmt.Fprintf(w, "  --ai on|off           AI assistance (on is not implemented)\n")
	fmt.Fprintf(w, "  -v, --verbose         verbose output\n")
	fmt.Fprintf(w, "  --no-color            disable coloured output\n")
	fmt.Fprintf(w, "  --version             print the version and exit\n")
}
