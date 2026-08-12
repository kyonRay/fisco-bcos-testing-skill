// Package paths resolves every directory fbt reads or writes. Env AND the launch working
// directory are injected rather than read from the process, so a test can pin every input without
// mutating global state -- and so a stray fbt.yaml appearing in the repository can never change
// what a test observes.
package paths

import (
	"os"
	"path/filepath"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Env is the subset of the environment that decides where things live.
type Env struct{ Home, XDGState, XDGConfig string }

func OSEnv() Env {
	return Env{
		Home:      os.Getenv("HOME"),
		XDGState:  os.Getenv("XDG_STATE_HOME"),
		XDGConfig: os.Getenv("XDG_CONFIG_HOME"),
	}
}

type Overrides struct{ ConfigFlag, EngineDirFlag, StateDirFlag string }

type Paths struct {
	State  string
	Config string
	// ConfigExplicit records that Config came from --config. A named file that is absent is an
	// infrastructure error (exit 30); an absent file at a default location is ordinary.
	ConfigExplicit bool
	InstallRoot    string
	Scripts        string
	// Tools is where install.sh puts tamper-helper.sh and the jar it runs. It exists as a field
	// because tools.tamper_helper otherwise has to be configured by hand on every machine, naming
	// a file the installer just placed at a location it alone decides.
	Tools        string
	EngineJSON   string
	Profiles     string
	ShippedCases string
	StateCases   string
	Clusters     string
}

// defaultInstallRoot derives the root from the running binary: <root>/bin/fbt means two levels up,
// so a relocated tarball works with no flags at all.
func defaultInstallRoot() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return filepath.Dir(filepath.Dir(exe))
}

// Resolve computes every path. cwd is the process launch directory, passed in explicitly: it is
// the base for relative flag values and the place ./fbt.yaml is looked for.
func Resolve(o Overrides, e Env, cwd string) (Paths, error) {
	var p Paths
	abs := func(s string) string {
		if s == "" || filepath.IsAbs(s) {
			return s
		}
		return filepath.Join(cwd, s)
	}

	// ---- state ----
	switch {
	case o.StateDirFlag != "":
		p.State = abs(o.StateDirFlag)
	case e.XDGState != "":
		p.State = filepath.Join(e.XDGState, "fbt")
	case e.Home != "":
		p.State = filepath.Join(e.Home, ".local", "state", "fbt")
	default:
		return p, fbterr.Configf("cannot locate a state directory: neither XDG_STATE_HOME nor " +
			"HOME is set, so --state-dir must be given explicitly (fbt will not guess where to " +
			"keep the cluster registry)")
	}

	// ---- config ----
	// A missing config file is fine; being unable to say WHERE one would live is not, because the
	// user then cannot tell whether their settings were read.
	localCandidate := filepath.Join(cwd, "fbt.yaml")
	switch {
	case o.ConfigFlag != "":
		p.Config, p.ConfigExplicit = abs(o.ConfigFlag), true
	case fileExists(localCandidate):
		p.Config = localCandidate
	case e.XDGConfig != "":
		p.Config = filepath.Join(e.XDGConfig, "fbt", "config.yaml")
	case e.Home != "":
		p.Config = filepath.Join(e.Home, ".config", "fbt", "config.yaml")
	default:
		return p, fbterr.Configf("cannot locate a configuration file: neither XDG_CONFIG_HOME " +
			"nor HOME is set and no ./fbt.yaml exists, so --config must be given explicitly")
	}

	// ---- install layout ----
	p.InstallRoot = abs(o.EngineDirFlag)
	if p.InstallRoot == "" {
		p.InstallRoot = defaultInstallRoot()
	}
	p.Scripts = filepath.Join(p.InstallRoot, "libexec", "fbt", "scripts")
	p.Tools = filepath.Join(p.InstallRoot, "libexec", "fbt", "tools")
	p.EngineJSON = filepath.Join(p.InstallRoot, "libexec", "fbt", "engine.json")
	p.Profiles = filepath.Join(p.InstallRoot, "share", "fbt", "profiles")
	p.ShippedCases = filepath.Join(p.InstallRoot, "share", "fbt", "cases")
	p.StateCases = filepath.Join(p.State, "cases")
	p.Clusters = filepath.Join(p.State, "clusters")
	return p, nil
}

func fileExists(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() }
