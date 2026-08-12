package paths

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/testinstall"
)

func env(home, xdgState, xdgConfig string) Env {
	return Env{Home: home, XDGState: xdgState, XDGConfig: xdgConfig}
}

// emptyCwd is a directory guaranteed to contain no fbt.yaml, so the ./fbt.yaml branch never fires
// by accident.
func emptyCwd(t *testing.T) string { t.Helper(); return t.TempDir() }

func TestStatePrefersFlagThenXDGThenHome(t *testing.T) {
	cwd := emptyCwd(t)
	p, err := Resolve(Overrides{}, env("/home/u", "/xdg/state", "/xdg/config"), cwd)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join("/xdg/state", "fbt"); p.State != want {
		t.Errorf("State = %q, want %q", p.State, want)
	}
	p, err = Resolve(Overrides{}, env("/home/u", "", ""), cwd)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join("/home/u", ".local", "state", "fbt"); p.State != want {
		t.Errorf("State = %q, want %q", p.State, want)
	}
	p, _ = Resolve(Overrides{StateDirFlag: "/explicit"}, env("/home/u", "/xdg/state", ""), cwd)
	if p.State != "/explicit" {
		t.Errorf("State = %q, want the --state-dir value", p.State)
	}
}

// spec §5: with neither XDG nor HOME, BOTH --state-dir and --config are required; each missing one
// is its own config error naming the flag the user has to add.
func TestNoXDGNoHomeRequiresBothFlags(t *testing.T) {
	cwd := emptyCwd(t)
	e := env("", "", "")

	_, err := Resolve(Overrides{}, e, cwd)
	if err == nil || !strings.Contains(err.Error(), "--state-dir") {
		t.Fatalf("want an error naming --state-dir, got %v", err)
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
		t.Errorf("want ClassConfig (exit 20), got %v", c)
	}

	// state satisfied, config still not
	_, err = Resolve(Overrides{StateDirFlag: "/s"}, e, cwd)
	if err == nil || !strings.Contains(err.Error(), "--config") {
		t.Fatalf("want an error naming --config, got %v", err)
	}

	// both given: succeeds
	p, err := Resolve(Overrides{StateDirFlag: "/s", ConfigFlag: "/c.yaml"}, e, cwd)
	if err != nil {
		t.Fatalf("both flags given, want success, got %v", err)
	}
	if p.State != "/s" || p.Config != "/c.yaml" || !p.ConfigExplicit {
		t.Errorf("got %+v", p)
	}
}

// ./fbt.yaml is looked for in the INJECTED cwd, never the process cwd -- otherwise a stray
// fbt.yaml committed to this repository would silently change these results.
func TestLocalConfigIsFoundInTheInjectedCwdOnly(t *testing.T) {
	cwd := t.TempDir()
	local := filepath.Join(cwd, "fbt.yaml")
	if err := os.WriteFile(local, []byte("fuzz:\n  batch: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// State is checked first, so give it a flag: this case is about config discovery only.
	p, err := Resolve(Overrides{StateDirFlag: "/s"}, env("", "", ""), cwd)
	if err != nil {
		t.Fatalf("./fbt.yaml should satisfy the config location: %v", err)
	}
	if p.Config != local {
		t.Errorf("Config = %q, want %q", p.Config, local)
	}
	if p.ConfigExplicit {
		t.Error("a discovered ./fbt.yaml is not an explicit --config")
	}

	// The same call from a different cwd must NOT find it.
	p, err = Resolve(Overrides{StateDirFlag: "/s", ConfigFlag: "/c.yaml"}, env("", "", ""), emptyCwd(t))
	if err != nil {
		t.Fatal(err)
	}
	if p.Config == local {
		t.Error("config leaked in from another directory")
	}
}

func TestConfigFallsBackXDGThenHome(t *testing.T) {
	cwd := emptyCwd(t)
	p, _ := Resolve(Overrides{}, env("/home/u", "/xdg/state", "/xdg/config"), cwd)
	if want := filepath.Join("/xdg/config", "fbt", "config.yaml"); p.Config != want {
		t.Errorf("Config = %q, want %q", p.Config, want)
	}
	p, _ = Resolve(Overrides{}, env("/home/u", "", ""), cwd)
	if want := filepath.Join("/home/u", ".config", "fbt", "config.yaml"); p.Config != want {
		t.Errorf("Config = %q, want %q", p.Config, want)
	}
}

// Relative flag values are resolved against the launch cwd, and every emitted path is absolute so
// a later chdir (the engine runs with the repo root as its cwd) cannot reinterpret them.
func TestRelativeFlagsAreAbsolutizedAgainstCwd(t *testing.T) {
	cwd := emptyCwd(t)
	p, err := Resolve(Overrides{StateDirFlag: "st", ConfigFlag: "c.yaml", EngineDirFlag: "inst"},
		env("", "", ""), cwd)
	if err != nil {
		t.Fatal(err)
	}
	for name, got := range map[string]string{
		"State": p.State, "Config": p.Config, "InstallRoot": p.InstallRoot,
		"Profiles": p.Profiles, "StateCases": p.StateCases,
	} {
		if !filepath.IsAbs(got) {
			t.Errorf("%s = %q is not absolute", name, got)
		}
		if !strings.HasPrefix(got, cwd) {
			t.Errorf("%s = %q was not resolved against cwd %q", name, got, cwd)
		}
	}
}

// --engine-dir names the whole install root: pointing only libexec at a custom root would read
// scripts from one install and profiles from another.
func TestEngineDirMovesEveryInstallPath(t *testing.T) {
	p, _ := Resolve(Overrides{EngineDirFlag: "/opt/fbt"}, env("/home/u", "/xdg/state", "/x"), emptyCwd(t))
	for name, want := range map[string]string{
		"Scripts":      "/opt/fbt/libexec/fbt/scripts",
		"EngineJSON":   "/opt/fbt/libexec/fbt/engine.json",
		"Profiles":     "/opt/fbt/share/fbt/profiles",
		"ShippedCases": "/opt/fbt/share/fbt/cases",
	} {
		got := map[string]string{"Scripts": p.Scripts, "EngineJSON": p.EngineJSON,
			"Profiles": p.Profiles, "ShippedCases": p.ShippedCases}[name]
		if got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
}

// The two case registries live apart on purpose: shipped is read-only, state is where fuzz writes.
func TestStateCasesLivesUnderStateNotInstall(t *testing.T) {
	p, _ := Resolve(Overrides{EngineDirFlag: "/opt/fbt"}, env("/home/u", "/xdg/state", "/x"), emptyCwd(t))
	if want := filepath.Join("/xdg/state", "fbt", "cases"); p.StateCases != want {
		t.Errorf("StateCases = %q, want %q", p.StateCases, want)
	}
	if want := filepath.Join("/xdg/state", "fbt", "clusters"); p.Clusters != want {
		t.Errorf("Clusters = %q, want %q", p.Clusters, want)
	}
}

// The shared fixture must produce an install Resolve accepts and that holds the files later tasks
// actually read.
func TestFixtureInstallIsUsable(t *testing.T) {
	ti := testinstall.New(t)
	p, err := Resolve(Overrides{EngineDirFlag: ti.Root, StateDirFlag: ti.State, ConfigFlag: "/none.yaml"},
		env("", "", ""), emptyCwd(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{
		p.EngineJSON,
		filepath.Join(p.Profiles, "default-latest.profile"),
		filepath.Join(p.Profiles, "production-enterprise.profile"),
	} {
		if !fileExists(f) {
			t.Errorf("fixture is missing %s", f)
		}
	}
	if !isDir(p.Scripts) || !isDir(p.ShippedCases) {
		t.Errorf("fixture is missing a required directory")
	}
}

func isDir(p string) bool { st, err := os.Stat(p); return err == nil && st.IsDir() }
