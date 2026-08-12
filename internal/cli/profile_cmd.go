package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/paths"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/profile"
)

func profileCommand(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("profile needs a subcommand: list or show"))
	}
	switch args[0] {
	case "list":
		return profileList(o, args[1:], stdout, stderr)
	case "show":
		return profileShow(o, args[1:], stdout, stderr)
	}
	return emitError(stdout, stderr, o.Output,
		fbterr.Configf("unknown subcommand %q; profile takes list or show", args[0]))
}

// profileDir resolves the installation and returns the profile directory, after parsing whatever
// global flags were given after the command name.
func profileDir(o *GlobalOptions, name string, args []string, stdout, stderr io.Writer) (paths.Paths, []string, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, o)
	if err := fs.Parse(args); err != nil {
		return paths.Paths{}, nil, fbterr.Configf("%v", err)
	}
	if err := finish(); err != nil {
		return paths.Paths{}, nil, err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return paths.Paths{}, nil, fbterr.Infraf("cannot determine the current directory: %v", err)
	}
	p, err := paths.Resolve(paths.Overrides{
		ConfigFlag: o.ConfigPath, EngineDirFlag: o.EngineDir, StateDirFlag: o.StateDir,
	}, paths.OSEnv(), cwd)
	return p, fs.Args(), err
}

func profileList(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	p, rest, err := profileDir(&o, "profile list", args, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if len(rest) > 0 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("profile list takes no arguments, got %v", rest))
	}
	// filepath.Glob returns an empty slice and NO error for a directory that does not exist, so a
	// broken installation would otherwise print an empty list and exit 0 -- a false green about
	// the one thing this command exists to report.
	if st, err := os.Stat(p.Profiles); err != nil || !st.IsDir() {
		return emitError(stdout, stderr, o.Output,
			fbterr.Infraf("profile directory %s is missing or not a directory "+
				"(is the installation complete? use --engine-dir to point at it)", p.Profiles))
	}
	files, err := filepath.Glob(filepath.Join(p.Profiles, "*.profile"))
	if err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Infraf("listing %s: %v", p.Profiles, err))
	}
	type entry struct {
		Name string `json:"name"`
		Path string `json:"path"`
	}
	list := make([]entry, 0, len(files))
	for _, f := range files {
		list = append(list, entry{Name: strings.TrimSuffix(filepath.Base(f), ".profile"), Path: f})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })

	if err := render(stdout, o.Output, map[string]interface{}{"profiles": list}, func(w io.Writer) {
		tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
		for _, e := range list {
			fmt.Fprintf(tw, "%s\t%s\n", e.Name, e.Path)
		}
		tw.Flush()
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

type kvOut struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func profileShow(o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	p, rest, err := profileDir(&o, "profile show", args, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if len(rest) != 1 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("profile show takes exactly one profile name or path"))
	}
	cwd, err := os.Getwd()
	if err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Infraf("cannot determine the current directory: %v", err))
	}
	path, err := profile.Resolve(rest[0], []string{p.Profiles}, cwd)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	prof, err := profile.Parse(path)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	// Replay and config_ini stay in FILE order. Sorting them would be a correctness bug, not a
	// cosmetic one: the balance feature flags have a dependency chain, and auth_check_status locks
	// out every setSystemConfigByKey that follows it.
	replay := make([]kvOut, 0, len(prof.Replay))
	for _, kv := range prof.Replay {
		replay = append(replay, kvOut{kv.Key, kv.Value})
	}
	ini := make([]kvOut, 0, len(prof.ConfigINI))
	for _, kv := range prof.ConfigINI {
		ini = append(ini, kvOut{kv.Key, kv.Value})
	}
	doc := map[string]interface{}{
		"path":                 prof.Path,
		"meta":                 prof.Meta,
		"genesis":              prof.Genesis,
		"system_config_replay": replay,
		"config_ini_override":  ini,
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		fmt.Fprintf(w, "%s\n\n", prof.Path)
		writeSortedMap(w, "[meta]", prof.Meta)
		writeSortedMap(w, "[genesis]", prof.Genesis)
		writeOrdered(w, "[system_config_replay]  (file order -- it is replayed verbatim)", replay)
		writeOrdered(w, "[config_ini_override]", ini)
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

func writeSortedMap(w io.Writer, title string, m map[string]string) {
	if len(m) == 0 {
		return
	}
	fmt.Fprintf(w, "%s\n", title)
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	for _, k := range ks {
		fmt.Fprintf(tw, "  %s\t%s\n", k, m[k])
	}
	tw.Flush()
	fmt.Fprintln(w)
}

func writeOrdered(w io.Writer, title string, kvs []kvOut) {
	if len(kvs) == 0 {
		return
	}
	fmt.Fprintf(w, "%s\n", title)
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	for _, kv := range kvs {
		fmt.Fprintf(tw, "  %s\t%s\n", kv.Key, kv.Value)
	}
	tw.Flush()
	fmt.Fprintln(w)
}
