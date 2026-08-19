// Package doctor decides what each command needs and checks it BEFORE the command touches a chain.
//
// The matrix is per command, not one list for everything (spec §5). A single global list is what
// makes a tool refuse to tear down a broken cluster because Viem is missing -- and tearing down a
// broken cluster is exactly what someone whose machine is half-installed needs to do.
package doctor

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Kind is how a requirement is checked. It decides the probe, and with it the failure class.
type Kind int

const (
	// KindExecutable: a program that must be on PATH. Absence is always infrastructure -- there is
	// no configuration key the user could have filled in instead.
	KindExecutable Kind = iota
	// KindPath: a file or directory named by a config key. Two different failures: the key is
	// unset (the user has not said where it is -- 20), or it is set and points nowhere (30).
	KindPath
	// KindValue: a config key that must merely be non-empty, e.g. tools.web3_private_key. Only
	// ever 20; there is nothing on disk to check.
	KindValue
	// KindNodeModule: an npm package the engine imports at run time. Resolution walks node_modules
	// upward from the WORKING DIRECTORY, so it is probed from the same directory the engine runs
	// in -- checking from anywhere else answers a different question than the one that matters.
	// Absence is infrastructure: there is no config key that installs a package.
	KindNodeModule
	// KindBashVersion: bash 4+, checked by asking the interpreter itself. Stock macOS ships 3.2
	// and every script in the engine fails on it with an obscure parse error, so this is checked
	// up front rather than discovered as a syntax error mid-round.
	KindBashVersion
)

// Requirement is one row of the matrix.
type Requirement struct {
	Name string
	Kind Kind
	// ConfigKey supplies the path or value. Empty for KindExecutable and KindBashVersion.
	ConfigKey string
	// Exe is the program name for KindExecutable.
	Exe string
	// Module is the package name for KindNodeModule.
	Module string
	// Scenarios narrows a gate requirement to the scenario families that actually need it. Empty
	// means every gate round needs it. This is what makes `--scenarios malformed` stop demanding
	// Node and Viem -- checking dependencies of work that was not selected is how a tool refuses
	// to run for reasons that have nothing to do with the request.
	Scenarios []string
	// Why is shown when the requirement is missing.
	Why string
}

// matrix is the whole dependency table, one entry per command (spec §5).
var matrix = map[string][]Requirement{
	"gate": {
		{Name: "bash4", Kind: KindBashVersion,
			Why: "every engine script uses associative arrays; stock macOS bash 3.2 fails with a parse error"},
		{Name: "curl", Kind: KindExecutable, Exe: "curl", Why: "the web3 RPC is driven over HTTP"},
		{Name: "pgrep", Kind: KindExecutable, Exe: "pgrep", Why: "the crash oracle looks for node processes"},
		{Name: "repo", Kind: KindPath, ConfigKey: "repo.root",
			Why: "the FISCO-BCOS checkout the release candidate is built from"},
		{Name: "node-binary", Kind: KindPath, ConfigKey: "tools.fisco_bin",
			Why: "the fisco-bcos binary under test"},
		{Name: "console", Kind: KindPath, ConfigKey: "tools.console_dir",
			Why: "the BCOS RPC path is driven through console.sh"},
		{Name: "java", Kind: KindPath, ConfigKey: "tools.java_bin",
			Why: "console and the fuzz driver are JVM programs"},
		{Name: "tamper-helper", Kind: KindPath, ConfigKey: "tools.tamper_helper",
			Scenarios: []string{"malformed"},
			Why:       "the malformed scenario byte-tampers a signed transaction with it"},
		{Name: "web3-key", Kind: KindValue, ConfigKey: "tools.web3_private_key",
			Scenarios: []string{"dual_rpc", "jsd"},
			Why:       "the web3 RPC path signs its own transactions"},
		{Name: "node-runtime", Kind: KindExecutable, Exe: "node",
			Scenarios: []string{"dual_rpc", "jsd"},
			Why:       "the web3 leg derives its address and signs its transactions through Viem"},
		// Viem's absence used to surface as a dual_rpc FAILURE -- exit 10, "the chain failed the
		// gate" -- for a release candidate that was never tested. A missing npm package is the
		// machine's problem, and it has to be said before a chain is built, not after.
		{Name: "viem", Kind: KindNodeModule, Module: "viem",
			Scenarios: []string{"dual_rpc", "jsd"},
			Why:       "the web3 leg builds and signs its transactions with it"},
		{Name: "jsd", Kind: KindPath, ConfigKey: "jsd.dir",
			Scenarios: []string{"jsd"},
			Why:       "the JSD driver's own directory"},
		{Name: "ut-binaries", Kind: KindPath, ConfigKey: "tools.build_dir",
			Scenarios: []string{"ut"},
			Why:       "the built unit-test binaries live under the build directory"},
	},
	"fuzz": {
		// Deliberately NOT the gate list. fuzz attaches to a cluster somebody else built, so
		// demanding the checkout and console here would refuse a run that needs neither.
		{Name: "bash4", Kind: KindBashVersion, Why: "the fuzz driver is a bash script"},
		{Name: "curl", Kind: KindExecutable, Exe: "curl", Why: "transactions are submitted over HTTP"},
		{Name: "java", Kind: KindPath, ConfigKey: "tools.java_bin", Why: "the fuzz driver is a JVM program"},
		{Name: "fuzz-jar", Kind: KindPath, ConfigKey: "tools.fuzz_jar", Why: "the fuzz driver itself"},
	},
	"case": {
		{Name: "bash4", Kind: KindBashVersion, Why: "run_case.sh is a bash script"},
		{Name: "curl", Kind: KindExecutable, Exe: "curl", Why: "a case input is usually an RPC call"},
		{Name: "repo", Kind: KindPath, ConfigKey: "repo.root", Why: "a case reproduces a profile locally"},
		{Name: "node-binary", Kind: KindPath, ConfigKey: "tools.fisco_bin", Why: "the binary under test"},
	},
	// Bringing a cluster up runs the whole of apply_profile.sh: build_chain, the config.ini patch,
	// and the console replay of every [system_config_replay] pair. It is the gate list minus the
	// scenario-specific entries -- no scenario runs here, so Viem, the tamper helper and the UT
	// binaries are none of its business.
	"cluster-up": {
		{Name: "bash4", Kind: KindBashVersion, Why: "apply_profile.sh uses associative arrays"},
		{Name: "curl", Kind: KindExecutable, Exe: "curl", Why: "bring-up waits for RPC to answer"},
		{Name: "repo", Kind: KindPath, ConfigKey: "repo.root",
			Why: "build_chain.sh lives in the checkout"},
		{Name: "node-binary", Kind: KindPath, ConfigKey: "tools.fisco_bin",
			Why: "the fisco-bcos binary the cluster runs"},
		{Name: "console", Kind: KindPath, ConfigKey: "tools.console_dir",
			Why: "the profile's setSystemConfigByKey replay goes through console.sh"},
		{Name: "java", Kind: KindPath, ConfigKey: "tools.java_bin", Why: "the console is a JVM program"},
	},
	// Teardown and inspection check NOTHING. Spec §5 is explicit: never refuse to stop a cluster
	// because java or Viem is missing. A half-installed machine with a stuck cluster is precisely
	// the situation where `cluster down` has to work.
	"cluster-down": {},
	"cluster-ls":   {},
}

// Commands lists every command the matrix knows, for tests and for `fbt doctor --help`.
func Commands() []string {
	out := make([]string, 0, len(matrix))
	for k := range matrix {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Plan returns the requirements that apply to one invocation.
//
// scenarios narrows a gate round to the families actually selected; nil means all of them.
func Plan(command string, scenarios []string) ([]Requirement, error) {
	reqs, ok := matrix[command]
	if !ok {
		return nil, fbterr.Hostf("no dependency matrix is defined for %q", command)
	}
	if len(scenarios) == 0 {
		return append([]Requirement(nil), reqs...), nil
	}
	sel := map[string]bool{}
	for _, s := range scenarios {
		sel[s] = true
	}
	out := make([]Requirement, 0, len(reqs))
	for _, r := range reqs {
		if len(r.Scenarios) == 0 {
			out = append(out, r) // needed by every round
			continue
		}
		for _, s := range r.Scenarios {
			if sel[s] {
				out = append(out, r)
				break
			}
		}
	}
	return out, nil
}

// Finding is one requirement's verdict.
type Finding struct {
	Name     string `json:"name"`
	Required bool   `json:"required"`
	Present  bool   `json:"present"`
	// Class is empty when Present. Otherwise "config" (the user has not said where it is) or
	// "infra" (they did, and it is not there) -- the distinction spec §5 draws, and the one that
	// decides whether the operator edits fbt.yaml or fixes the machine.
	Class  string `json:"class,omitempty"`
	Detail string `json:"detail,omitempty"`
}

// Report is the whole matrix's verdict, and is the `fbt doctor --output json` document.
type Report struct {
	Exit int       `json:"exit"`
	Deps []Finding `json:"deps"`
}

// Probe abstracts the filesystem and PATH so the matrix can be tested without installing anything.
type Probe interface {
	LookPath(exe string) bool
	// NodeModule reports whether name is importable with dir as the working directory.
	NodeModule(dir, name string) bool
	Exists(path string) bool
	BashMajor() int
}

type OSProbe struct{}

func (OSProbe) LookPath(exe string) bool { _, err := exec.LookPath(exe); return err == nil }
func (OSProbe) Exists(path string) bool  { _, err := os.Stat(path); return err == nil }

// NodeModule asks node itself, from dir, rather than guessing at node_modules layouts: the engine
// resolves the package exactly this way, and viem is ESM-only so a require() probe would report it
// missing on a machine that has it.
func (OSProbe) NodeModule(dir, name string) bool {
	cmd := exec.Command("node", "--input-type=module", "-e", "import "+strconv.Quote(name))
	cmd.Dir = dir
	return cmd.Run() == nil
}

// BashMajor asks the bash on PATH for its own major version.
//
// It asks the interpreter rather than reading $BASH_VERSION, because that variable describes the
// shell that launched fbt -- which is not the shell the engine scripts will run under, and on a
// machine with a Homebrew bash ahead of /bin/bash on PATH the two differ by two major versions.
//
// `--version` rather than `-c 'echo ${BASH_VERSINFO[0]}'`: no shell interpretation is involved at
// all, so there is no construct here for anyone to later grow an interpolated argument into.
//
// LC_ALL=C is not decoration. bash localizes its banner, and this machine prints
// "GNU bash，版本 5.3.15(1)-release" -- a parser looking for the English word finds nothing,
// reports major 0, and doctor then refuses a perfectly good machine with "bash 4+ is required".
func (OSProbe) BashMajor() int {
	cmd := exec.Command("bash", "--version")
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	return parseBashMajor(string(out))
}

// parseBashMajor pulls N out of "GNU bash, version N.M.P(1)-release".
//
// It looks for the first NUMBER FOLLOWED BY A DOT rather than for the word "version", so it still
// works if the banner is localized despite the forced locale -- the digits are the one part no
// translation touches. Requiring the dot keeps it from latching onto a stray number in a
// distributor's banner.
func parseBashMajor(s string) int {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i] // the version is on the first line; later lines carry a copyright year
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			continue
		}
		n, j := 0, i
		for ; j < len(s) && s[j] >= '0' && s[j] <= '9'; j++ {
			n = n*10 + int(s[j]-'0')
		}
		if j < len(s) && s[j] == '.' {
			return n
		}
		i = j // skip the number we just rejected
	}
	return 0
}

// Check runs a plan and returns the report plus the error to fail with, or nil if everything the
// command needs is present.
//
// base is the ENGINE's working directory. Several built-in defaults are relative -- tools.
// console_dir is "console/dist", mirroring the engine's own ${CONSOLE_DIR:-console/dist} -- and
// the engine resolves those against its own cwd, which is the FISCO checkout, not wherever the
// user happened to type the command. Checking them against the host's cwd reports "console/dist
// does not exist" on a machine where the engine would find it immediately: a false red that
// refuses a perfectly good run.
func Check(plan []Requirement, config map[string]string, p Probe) (Report, error) {
	return CheckIn("", plan, config, p)
}

// CheckIn is Check with the engine's working directory supplied.
func CheckIn(base string, plan []Requirement, config map[string]string, p Probe) (Report, error) {
	rep := Report{Deps: make([]Finding, 0, len(plan))}
	var missingConfig, missingInfra []string

	for _, r := range plan {
		f := Finding{Name: r.Name, Required: true}
		switch r.Kind {
		case KindExecutable:
			f.Present = p.LookPath(r.Exe)
			if !f.Present {
				f.Class, f.Detail = "infra", r.Exe+" is not on PATH: "+r.Why
				missingInfra = append(missingInfra, f.Detail)
			}
		case KindNodeModule:
			f.Present = p.NodeModule(base, r.Module)
			if !f.Present {
				f.Class = "infra"
				f.Detail = "the node package " + r.Module + " cannot be imported from " + base +
					" (npm i " + r.Module + "): " + r.Why
				missingInfra = append(missingInfra, f.Detail)
			}
		case KindBashVersion:
			major := p.BashMajor()
			f.Present = major >= 4
			if !f.Present {
				f.Class = "infra"
				f.Detail = "bash 4+ is required (found major " + itoa(major) +
					"; on macOS: brew install bash): " + r.Why
				missingInfra = append(missingInfra, f.Detail)
			}
		case KindValue:
			v := config[r.ConfigKey]
			f.Present = v != ""
			if !f.Present {
				f.Class = "config"
				f.Detail = r.ConfigKey + " is not set: " + r.Why
				missingConfig = append(missingConfig, f.Detail)
			}
		case KindPath:
			raw := config[r.ConfigKey]
			// A value with no separator is a COMMAND NAME, not a path. tools.java_bin defaults to
			// "java", and the engine's ${JAVA_BIN:-java} is executed by a shell that resolves it on
			// PATH -- so treating it as a relative path and looking for <repo>/java reports a
			// missing dependency on every machine where java is installed normally.
			if raw != "" && !strings.ContainsRune(raw, filepath.Separator) {
				f.Present = p.LookPath(raw)
				if !f.Present {
					f.Class = "infra"
					f.Detail = r.ConfigKey + " is " + raw + ", which is not on PATH"
					missingInfra = append(missingInfra, f.Detail)
				}
				break
			}
			v := resolveAgainst(base, raw)
			switch {
			case v == "":
				// Not configured at all: the user has to say where it is. That is their file to
				// edit, not a broken machine.
				f.Class = "config"
				f.Detail = r.ConfigKey + " is not set: " + r.Why
				missingConfig = append(missingConfig, f.Detail)
			case !p.Exists(v):
				// Configured and absent: they said where it is and it is not there.
				f.Class = "infra"
				f.Detail = r.ConfigKey + " points at " + v + ", which does not exist"
				missingInfra = append(missingInfra, f.Detail)
			default:
				f.Present = true
			}
		}
		rep.Deps = append(rep.Deps, f)
	}

	// Configuration outranks infrastructure, matching the exit-code priority (20 over 30 would be
	// wrong -- §10 orders 30 above 20 -- but the MESSAGE leads with what the user must fix first,
	// and an unset key is something no amount of installing will resolve).
	switch {
	case len(missingConfig) > 0 && len(missingInfra) > 0:
		rep.Exit = 30
		return rep, fbterr.Infraf("%d dependencies are missing:\n  - %s\nand %d settings are "+
			"not configured:\n  - %s", len(missingInfra), strings.Join(missingInfra, "\n  - "),
			len(missingConfig), strings.Join(missingConfig, "\n  - "))
	case len(missingInfra) > 0:
		rep.Exit = 30
		return rep, fbterr.Infraf("%d dependencies are missing:\n  - %s",
			len(missingInfra), strings.Join(missingInfra, "\n  - "))
	case len(missingConfig) > 0:
		rep.Exit = 20
		return rep, fbterr.Configf("%d settings are not configured:\n  - %s",
			len(missingConfig), strings.Join(missingConfig, "\n  - "))
	}
	return rep, nil
}

// resolveAgainst makes a relative configured path absolute against the engine's working directory.
// An empty value stays empty: "not configured" must not turn into "configured, pointing at base".
func resolveAgainst(base, v string) string {
	if v == "" || base == "" || filepath.IsAbs(v) {
		return v
	}
	return filepath.Join(base, v)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [8]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
