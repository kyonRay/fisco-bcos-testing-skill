package config

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/profile"
)

func mustMerge(t *testing.T, in Inputs) Resolved {
	t.Helper()
	r, err := Merge(in)
	if err != nil {
		t.Fatalf("Merge: %v", err)
	}
	return r
}

// prof builds a Profile in memory; Parse is tested in its own package, and going through a file
// here would only couple these tests to the parser.
func prof(genesis map[string]string, ini ...profile.KV) *profile.Profile {
	if genesis == nil {
		genesis = map[string]string{"compatibility_version": "3.16.4"}
	}
	return &profile.Profile{Genesis: genesis, ConfigINI: ini}
}

// spec §7.1: flag > env > fbt.yaml > .profile > built-in default.
func TestLayerPrecedence(t *testing.T) {
	in := Inputs{
		Defaults: map[string]string{"fuzz.batch": "100"},
		Profile:  prof(nil, profile.KV{Key: "web3_rpc.listen_port", Value: "8545"}),
		File:     map[string]string{"fuzz.batch": "200", "cluster.web3_base_port": "8600"},
		Env:      map[string]string{"fuzz.batch": "300"},
		Flags:    map[string]string{"fuzz.batch": "400"},
	}
	got := mustMerge(t, in)
	if got["fuzz.batch"].S != "400" || got["fuzz.batch"].From != SourceFlag {
		t.Errorf("fuzz.batch = %+v, want 400 from flag", got["fuzz.batch"])
	}
	// The profile's port is present but outranked by fbt.yaml.
	if got["cluster.web3_base_port"].S != "8600" || got["cluster.web3_base_port"].From != SourceFile {
		t.Errorf("cluster.web3_base_port = %+v, want 8600 from fbt.yaml", got["cluster.web3_base_port"])
	}

	// Peel one layer off at a time; each remaining top layer must take over.
	in.Flags = nil
	if got := mustMerge(t, in); got["fuzz.batch"].S != "300" || got["fuzz.batch"].From != SourceEnv {
		t.Errorf("without flags: %+v, want 300 from env", got["fuzz.batch"])
	}
	in.Env = nil
	if got := mustMerge(t, in); got["fuzz.batch"].S != "200" || got["fuzz.batch"].From != SourceFile {
		t.Errorf("without env: %+v, want 200 from fbt.yaml", got["fuzz.batch"])
	}
	in.File = nil
	if got := mustMerge(t, in); got["fuzz.batch"].S != "100" || got["fuzz.batch"].From != SourceDefault {
		t.Errorf("without fbt.yaml: %+v, want 100 from the built-in default", got["fuzz.batch"])
	}
	if got := mustMerge(t, in); got["cluster.web3_base_port"].S != "8545" ||
		got["cluster.web3_base_port"].From != SourceProfile {
		t.Errorf("without fbt.yaml: %+v, want the profile's 8545", got["cluster.web3_base_port"])
	}
}

// The environment is the escape hatch operators actually reach for; WEB3_BASE overriding the
// profile's captured port is the concrete case (a second chain on the same host).
func TestHostEnvOutranksTheProfilePort(t *testing.T) {
	got := mustMerge(t, Inputs{
		Profile: prof(nil, profile.KV{Key: "web3_rpc.listen_port", Value: "8545"}),
		Env:     map[string]string{"cluster.web3_base_port": "8600"},
	})
	if got["cluster.web3_base_port"].S != "8600" || got["cluster.web3_base_port"].From != SourceEnv {
		t.Errorf("got %+v, want 8600 from env", got["cluster.web3_base_port"])
	}
}

// spec §7.1: genesis keys come ONLY from the .profile. A run whose genesis version could be
// overridden from fbt.yaml would reproduce a different chain than the profile it names.
func TestGenesisComesOnlyFromTheProfile(t *testing.T) {
	base := Inputs{Profile: prof(map[string]string{"compatibility_version": "3.16.4"})}
	got := mustMerge(t, base)
	if got["genesis.compatibility_version"].S != "3.16.4" ||
		got["genesis.compatibility_version"].From != SourceProfile {
		t.Fatalf("got %+v", got["genesis.compatibility_version"])
	}
	for name, in := range map[string]Inputs{
		"fbt.yaml": {Profile: base.Profile, File: map[string]string{"genesis.compatibility_version": "3.17.0"}},
		"env":      {Profile: base.Profile, Env: map[string]string{"genesis.compatibility_version": "3.17.0"}},
		"flag":     {Profile: base.Profile, Flags: map[string]string{"genesis.compatibility_version": "3.17.0"}},
		"default":  {Profile: base.Profile, Defaults: map[string]string{"genesis.compatibility_version": "3.17.0"}},
	} {
		_, err := Merge(in)
		if err == nil {
			t.Errorf("%s was allowed to set a genesis key", name)
			continue
		}
		if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
			t.Errorf("%s: want ClassConfig (exit 20), got %v", name, c)
		}
	}
}

// spec §7.8: only the explicitly listed entry becomes a canonical key. The rest are config.ini
// patches the engine applies straight from the profile file; leaking them in as configuration
// would make `config show` claim fbt controls settings it never touches.
func TestOnlyMappedConfigINIEntriesBecomeKeys(t *testing.T) {
	got := mustMerge(t, Inputs{Profile: prof(nil,
		profile.KV{Key: "web3_rpc.listen_port", Value: "8545"},
		profile.KV{Key: "executor.enable_dag", Value: "true"},
		profile.KV{Key: "txpool.limit", Value: "15000"},
	)})
	if got["cluster.web3_base_port"].S != "8545" {
		t.Errorf("the mapped entry did not become cluster.web3_base_port: %+v", got)
	}
	for _, leaked := range []string{"executor.enable_dag", "txpool.limit"} {
		if _, ok := got[leaked]; ok {
			t.Errorf("%q leaked into the resolved configuration", leaked)
		}
	}
}

// Values are validated wherever they enter, not only in fbt.yaml -- otherwise `abc` reaches
// `config show` intact and only explodes inside bash.
func TestInvalidValuesAreRejectedInEveryLayer(t *testing.T) {
	p := prof(nil, profile.KV{Key: "web3_rpc.listen_port", Value: "70000"})
	for name, in := range map[string]Inputs{
		"default": {Defaults: map[string]string{"fuzz.batch": "abc"}},
		"profile": {Profile: p},
		"file":    {File: map[string]string{"fuzz.batch": "abc"}},
		"env":     {Env: map[string]string{"fuzz.batch": "abc"}},
		"flag":    {Flags: map[string]string{"run.timeout_sec": "abc"}},
	} {
		_, err := Merge(in)
		if err == nil {
			t.Errorf("%s layer accepted an invalid value", name)
			continue
		}
		if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
			t.Errorf("%s: want ClassConfig, got %v", name, c)
		}
	}
}

func TestUnknownKeyIsRejectedInEveryLayerAndNamesTheLayer(t *testing.T) {
	for name, in := range map[string]Inputs{
		"fbt.yaml": {File: map[string]string{"fuzz.nope": "1"}},
		"env":      {Env: map[string]string{"fuzz.nope": "1"}},
		"flag":     {Flags: map[string]string{"fuzz.nope": "1"}},
	} {
		_, err := Merge(in)
		if err == nil {
			t.Fatalf("%s accepted an unknown key", name)
		}
		if !strings.Contains(err.Error(), "fuzz.nope") || !strings.Contains(err.Error(), name) {
			t.Errorf("%s: error should name both the key and the layer, got %v", name, err)
		}
	}
}

// EngineValues feeds keys.Translate, which refuses unknown keys -- so genesis keys must be gone
// by then, and host-only keys carry no env binding to inject.
func TestEngineValuesDropsGenesisAndHostOnlyKeys(t *testing.T) {
	got := mustMerge(t, Inputs{
		Profile: prof(map[string]string{"compatibility_version": "3.16.4", "feature_evm_cancun": "1"}),
		File:    map[string]string{"fuzz.batch": "60", "run.timeout_sec": "900", "cluster.node_count": "4"},
	}).EngineValues()

	if got["fuzz.batch"] != "60" {
		t.Errorf("fuzz.batch missing from EngineValues: %+v", got)
	}
	for _, k := range []string{"genesis.compatibility_version", "genesis.feature_evm_cancun",
		"run.timeout_sec", "cluster.node_count"} {
		if _, ok := got[k]; ok {
			t.Errorf("%q must not reach the engine environment", k)
		}
	}
	if _, err := keys.Translate(got); err != nil {
		t.Errorf("EngineValues output must be translatable: %v", err)
	}
}

func TestSourceStringsAreStableAndDistinct(t *testing.T) {
	seen := map[string]bool{}
	for _, s := range []Source{SourceDefault, SourceProfile, SourceFile, SourceEnv, SourceFlag} {
		if s.String() == "" || seen[s.String()] {
			t.Errorf("Source(%d).String() = %q is empty or duplicated", s, s.String())
		}
		seen[s.String()] = true
	}
}

// Every built-in default must be a known key with a valid value; a typo here would otherwise
// surface as a confusing error on a config the user never wrote.
func TestDefaultsAreSelfConsistent(t *testing.T) {
	d := Defaults()
	if len(d) < 15 {
		t.Fatalf("Defaults() has only %d entries -- suspiciously empty", len(d))
	}
	for k, v := range d {
		if !keys.IsKnown(k) {
			t.Errorf("default for unknown key %q", k)
			continue
		}
		if err := keys.Validate(k, v); err != nil {
			t.Errorf("default %s=%q is invalid: %v", k, v, err)
		}
	}
	if _, err := Merge(Inputs{Defaults: d}); err != nil {
		t.Errorf("Defaults() must merge cleanly: %v", err)
	}
}

var shellDefault = regexp.MustCompile(`\$\{([A-Z][A-Z0-9_]*):-([^}$]*)\}`)

// The engine already has defaults, written as ${NAME:-value} in bash. If the host's built-in
// defaults disagree, fbt silently changes what the engine does while reporting the same profile.
// This scan pins each default to the literal the scripts themselves use, and only accepts keys
// whose default is unambiguous across every occurrence.
func TestEveryBuiltinDefaultMatchesTheEnginesOwn(t *testing.T) {
	dirs := []string{"../../scripts", "../../tools", "../../../fisco-bcos-testing/scripts"}
	found := map[string]map[string]bool{} // env name -> set of default literals
	files := 0
	for _, d := range dirs {
		err := filepath.Walk(d, func(p string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() || !strings.HasSuffix(p, ".sh") {
				return err
			}
			files++
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			for _, m := range shellDefault.FindAllStringSubmatch(string(b), -1) {
				if found[m[1]] == nil {
					found[m[1]] = map[string]bool{}
				}
				found[m[1]][m[2]] = true
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", d, err)
		}
	}
	if files < 15 {
		t.Fatalf("scanned only %d .sh files -- wrong paths; this test would pass vacuously", files)
	}
	if len(found) < 30 {
		t.Fatalf("found only %d ${NAME:-...} defaults -- the regex or the paths are wrong", len(found))
	}

	for key, val := range Defaults() {
		r, ok := keys.Lookup(key)
		if !ok || len(r.Env) == 0 {
			continue // host-only defaults have no engine counterpart to compare against
		}
		name := r.Env[0]
		lits, ok := found[name]
		if !ok {
			t.Errorf("%s defaults to %q, but no script writes ${%s:-...} -- either the default is "+
				"invented or the engine stopped reading it", key, val, name)
			continue
		}
		if len(lits) != 1 {
			t.Errorf("%s: the scripts give %s more than one default (%v); a key whose engine "+
				"default is ambiguous must not get a built-in default at all", key, name, lits)
			continue
		}
		if !lits[val] {
			t.Errorf("%s = %q disagrees with the engine's own ${%s:-%v}", key, val, name, lits)
		}
	}
}

// cluster.web3_rpc_url is the concrete reason the rule above exists: oracle_lib.sh:123 treats
// WEB3_RPC_URL as a host-injected OVERRIDE and refuses to probe when it disagrees with node0's
// config.ini, so a built-in 127.0.0.1:8545 would break every chain on another port.
func TestWeb3RPCURLHasNoBuiltinDefault(t *testing.T) {
	if v, ok := Defaults()["cluster.web3_rpc_url"]; ok {
		t.Errorf("cluster.web3_rpc_url must have no built-in default, got %q", v)
	}
}

// A gate round on a machine that already runs a chain has to move its ports. When it does, the RPC
// URLs must move with them: the engine's own fallbacks are the literals http://127.0.0.1:20200 and
// :8545, so a run configured onto 21200/9545 sent its dual_rpc traffic to whatever was listening on
// the DEFAULT ports -- a different chain entirely, which answered.
func TestRPCURLsFollowTheConfiguredPortBases(t *testing.T) {
	got, err := Merge(Inputs{
		Defaults: Defaults(),
		File: map[string]string{
			"cluster.bcos_base_port": "21200",
			"cluster.web3_base_port": "9545",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if v := got["cluster.bcos_rpc_url"]; v.S != "http://127.0.0.1:21200" {
		t.Errorf("bcos_rpc_url = %q, want it to follow bcos_base_port", v.S)
	}
	if v := got["cluster.web3_rpc_url"]; v.S != "http://127.0.0.1:9545" {
		t.Errorf("web3_rpc_url = %q, want it to follow web3_base_port", v.S)
	}
	// The derived value reports the layer that actually decided it, not "built-in default" -- an
	// operator reading `config show` needs to see that their fbt.yaml is what moved it.
	if v := got["cluster.bcos_rpc_url"]; v.From != SourceFile {
		t.Errorf("bcos_rpc_url From = %v, want fbt.yaml", v.From)
	}
}

// An explicit URL is a deliberate override -- pointing the gate at a node other than node0, or at
// another host entirely. Derivation must never overwrite it.
func TestAnExplicitRPCURLOutranksTheDerivedOne(t *testing.T) {
	got, err := Merge(Inputs{
		Defaults: Defaults(),
		File:     map[string]string{"cluster.bcos_base_port": "21200"},
		Env:      map[string]string{"cluster.bcos_rpc_url": "http://10.0.0.5:20203"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if v := got["cluster.bcos_rpc_url"]; v.S != "http://10.0.0.5:20203" {
		t.Errorf("bcos_rpc_url = %q, want the explicit value", v.S)
	}
}

// With the ports left alone, nothing is derived: web3_rpc_url stays ABSENT so oracle_lib.sh keeps
// resolving it from node0's config.ini (see the deliberate-omission note on Defaults).
func TestDefaultPortsDeriveNothing(t *testing.T) {
	got, err := Merge(Inputs{Defaults: Defaults()})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got["cluster.web3_rpc_url"]; ok {
		t.Error("web3_rpc_url was invented with no web3_base_port set")
	}
	if v := got["cluster.bcos_rpc_url"]; v.S != "http://127.0.0.1:20200" {
		t.Errorf("bcos_rpc_url = %q, want the built-in default untouched", v.S)
	}
}
