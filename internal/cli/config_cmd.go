package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/config"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/paths"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/profile"
)

func init() {
	commands["config"] = configCommand
	commands["profile"] = profileCommand
}

// redacted is what a secret's value prints as. No prefix is kept: the first characters of a
// private key are still part of the private key.
const redacted = "<redacted>"

// environMap snapshots the process environment for the env configuration layer. Taking it as data
// keeps every layer below testable without mutating the real environment.
func environMap() map[string]string {
	out := map[string]string{}
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i > 0 {
			out[kv[:i]] = kv[i+1:]
		}
	}
	return out
}

// resolveAll wires all five configuration layers (spec §7.1). Anything less would make
// `config show` print "what the config file says" rather than "what this run will use".
func resolveAll(o GlobalOptions, profileSpec, cwd string, env map[string]string) (paths.Paths, config.Resolved, error) {
	p, err := paths.Resolve(paths.Overrides{
		ConfigFlag: o.ConfigPath, EngineDirFlag: o.EngineDir, StateDirFlag: o.StateDir,
	}, paths.OSEnv(), cwd)
	if err != nil {
		return p, nil, err
	}
	file, err := config.LoadFile(p.Config, p.ConfigExplicit)
	if err != nil {
		return p, nil, err
	}
	var prof *profile.Profile
	if profileSpec != "" {
		path, err := profile.Resolve(profileSpec, []string{p.Profiles}, cwd)
		if err != nil {
			return p, nil, err
		}
		parsed, err := profile.Parse(path)
		if err != nil {
			return p, nil, err
		}
		prof = &parsed
	}
	// The flag layer carries the paths the host itself resolved. They are not user opinions: they
	// are where the engine actually lives for this invocation, so they must outrank a stale
	// engine.scripts_dir left in someone's fbt.yaml.
	resolved, err := config.Merge(config.Inputs{
		Defaults: config.Defaults(),
		Profile:  prof,
		File:     file,
		Env:      keys.FromLegacyEnv(env),
		Flags: map[string]string{
			"engine.scripts_dir": p.Scripts,
			"engine.profile_dir": p.Profiles,
			"engine.state_cases": p.StateCases,
		},
	})
	return p, resolved, err
}

type shownKey struct {
	Key    string   `json:"key"`
	Value  string   `json:"value"`
	Source string   `json:"source"`
	Env    []string `json:"env,omitempty"`
	Set    bool     `json:"set"`
	Secret bool     `json:"secret,omitempty"`
}

func configCommand(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("config needs a subcommand: show or path"))
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "show":
		return configShow(o, rest, stdout, stderr)
	case "path":
		return configPath(o, rest, stdout, stderr)
	}
	return emitError(stdout, stderr, o.Output,
		fbterr.Configf("unknown subcommand %q; config takes show or path", sub))
}

func configShow(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("config show", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var profileSpec, command string
	var allKeys bool
	fs.StringVar(&profileSpec, "p", "", "profile name or path")
	fs.StringVar(&profileSpec, "profile", "", "profile name or path")
	fs.StringVar(&command, "command", "", "restrict to one command's dependency surface")
	fs.BoolVar(&allKeys, "all-keys", false, "list every registry key, including unset ones")
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if command != "" && !keys.IsKnownCommand(command) {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("--command %q is not an fbt command; known commands: %s",
				command, strings.Join(keys.KnownCommands(), ", ")))
	}

	cwd, err := os.Getwd()
	if err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Infraf("cannot determine the current directory: %v", err))
	}
	_, resolved, err := resolveAll(o, profileSpec, cwd, environMap())
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	rows := keys.Rows()
	if command != "" {
		rows = keys.RowsForCommand(command)
	}
	inSurface := map[string]keys.Row{}
	for _, r := range rows {
		inSurface[r.Key] = r
	}

	var shown []shownKey
	for key, v := range resolved {
		if strings.HasPrefix(key, config.GenesisPrefix) {
			// Genesis keys are not registry keys -- their names are whatever the captured chain
			// had -- so no command surface can claim or exclude them.
			shown = append(shown, shownKey{Key: key, Value: v.S, Source: v.From.String(), Set: true})
			continue
		}
		r, ok := inSurface[key]
		if !ok {
			continue
		}
		shown = append(shown, shownKey{Key: key, Value: redact(r, v.S), Source: v.From.String(),
			Env: r.Env, Set: true, Secret: r.Secret})
	}
	if allKeys {
		// spec §6.3: unknown-key errors tell the user to run `config show --all-keys`; listing
		// only keys that already have values would make that advice a dead end.
		for _, r := range rows {
			if _, set := resolved[r.Key]; set {
				continue
			}
			shown = append(shown, shownKey{Key: r.Key, Env: r.Env, Secret: r.Secret})
		}
	}
	sort.Slice(shown, func(i, j int) bool { return shown[i].Key < shown[j].Key })

	doc := map[string]interface{}{"keys": shown}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
		fmt.Fprintln(tw, "KEY\tVALUE\tSOURCE\tENV")
		for _, s := range shown {
			val, src := s.Value, s.Source
			if !s.Set {
				val, src = "-", "-"
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", s.Key, val, src, strings.Join(s.Env, ","))
		}
		tw.Flush()
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

// redact hides a secret's value on every output path. An empty value stays empty: printing
// "<redacted>" for a key nobody set would claim a secret exists.
func redact(r keys.Row, v string) string {
	if r.Secret && v != "" {
		return redacted
	}
	return v
}

func configPath(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("config path", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Infraf("cannot determine the current directory: %v", err))
	}
	p, err := paths.Resolve(paths.Overrides{
		ConfigFlag: o.ConfigPath, EngineDirFlag: o.EngineDir, StateDirFlag: o.StateDir,
	}, paths.OSEnv(), cwd)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	doc := map[string]interface{}{
		"config":          p.Config,
		"config_explicit": p.ConfigExplicit,
		"state":           p.State,
		"install_root":    p.InstallRoot,
		"scripts":         p.Scripts,
		"engine_json":     p.EngineJSON,
		"profiles":        p.Profiles,
		"shipped_cases":   p.ShippedCases,
		"state_cases":     p.StateCases,
		"clusters":        p.Clusters,
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
		ks := make([]string, 0, len(doc))
		for k := range doc {
			ks = append(ks, k)
		}
		sort.Strings(ks)
		for _, k := range ks {
			fmt.Fprintf(tw, "%s\t%v\n", k, doc[k])
		}
		tw.Flush()
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}
