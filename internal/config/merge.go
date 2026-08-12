package config

import (
	"sort"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/profile"
)

// Source says which layer a value came from. `config show` prints it, and it is the only way a
// user can tell why a setting has the value it has.
type Source int

const (
	SourceDefault Source = iota
	SourceProfile
	SourceFile
	SourceEnv
	SourceFlag
)

func (s Source) String() string {
	switch s {
	case SourceDefault:
		return "default"
	case SourceProfile:
		return "profile"
	case SourceFile:
		return "fbt.yaml"
	case SourceEnv:
		return "env"
	case SourceFlag:
		return "flag"
	}
	return "unknown"
}

type Value struct {
	S    string
	From Source
}

// Resolved is the final configuration: every key that has a value, with the layer it came from.
type Resolved map[string]Value

// GenesisPrefix marks the keys that describe the chain the profile captured. They are not in the
// key registry -- their names are whatever the captured chain had -- and spec §7.1 confines them
// to the .profile layer.
const GenesisPrefix = "genesis."

// configINIMap is spec §7.8's explicit list: which [config_ini_override] entries also decide host
// behaviour and therefore become canonical keys. Everything else in that section is a node
// config.ini patch that apply_profile.sh reads straight from the profile file. Explicit entries
// only -- no prefix wildcards, because guessing here would silently claim fbt controls settings it
// never touches.
var configINIMap = map[string]string{
	"web3_rpc.listen_port": "cluster.web3_base_port",
}

// Inputs are the five layers, lowest first. Env must already hold canonical keys: the caller runs
// keys.FromLegacyEnv (spec §7.6), which keeps Merge a pure function that tests never have to poke
// the process environment to exercise.
type Inputs struct {
	Defaults map[string]string
	Profile  *profile.Profile
	File     map[string]string
	Env      map[string]string
	Flags    map[string]string
}

func Merge(in Inputs) (Resolved, error) {
	out := Resolved{}
	if err := apply(out, in.Defaults, SourceDefault); err != nil {
		return nil, err
	}
	if in.Profile != nil {
		fromProfile := map[string]string{}
		for k, v := range in.Profile.Genesis {
			fromProfile[GenesisPrefix+k] = v
		}
		for _, kv := range in.Profile.ConfigINI {
			if canonical, mapped := configINIMap[kv.Key]; mapped {
				fromProfile[canonical] = kv.Value
			}
		}
		if err := apply(out, fromProfile, SourceProfile); err != nil {
			return nil, err
		}
	}
	if err := apply(out, in.File, SourceFile); err != nil {
		return nil, err
	}
	if err := apply(out, in.Env, SourceEnv); err != nil {
		return nil, err
	}
	if err := apply(out, in.Flags, SourceFlag); err != nil {
		return nil, err
	}
	return out, nil
}

// apply writes one layer over what is already there. Keys are walked in sorted order so a layer
// with several problems always reports the same one first.
func apply(out Resolved, layer map[string]string, src Source) error {
	ks := make([]string, 0, len(layer))
	for k := range layer {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	for _, k := range ks {
		if strings.HasPrefix(k, GenesisPrefix) {
			if src != SourceProfile {
				return fbterr.Configf("%s: %q comes only from the .profile -- a run whose genesis "+
					"could be overridden here would reproduce a different chain than the profile "+
					"it names", src, k)
			}
			out[k] = Value{S: layer[k], From: src}
			continue
		}
		if !keys.IsKnown(k) {
			return fbterr.Configf("%s: unknown config key %q; run `fbt config show --all-keys` "+
				"for the full key list", src, k)
		}
		if err := keys.Validate(k, layer[k]); err != nil {
			return fbterr.Configf("%s: %v", src, err)
		}
		out[k] = Value{S: layer[k], From: src}
	}
	return nil
}

// EngineValues narrows the resolved configuration to what the engine's environment can carry:
// genesis keys are not registry keys at all, and host-only keys have no env binding. The result is
// what keys.Translate consumes.
func (r Resolved) EngineValues() map[string]string {
	out := make(map[string]string, len(r))
	for k, v := range r {
		row, ok := keys.Lookup(k)
		if !ok || len(row.Env) == 0 {
			continue
		}
		out[k] = v.S
	}
	return out
}

// Defaults are the built-in bottom layer. Each one is the literal the engine scripts already use
// in their own ${NAME:-value}, so running fbt with no configuration behaves exactly as running the
// scripts directly -- TestEveryBuiltinDefaultMatchesTheEnginesOwn enforces that mechanically.
//
// A key gets a default here only when every occurrence in the scripts agrees on it. Deliberate
// omissions:
//   - cluster.web3_rpc_url: oracle_lib.sh:123 treats WEB3_RPC_URL as a host-injected OVERRIDE and
//     refuses to probe when it disagrees with node0's config.ini, so a built-in 127.0.0.1:8545
//     would break every chain listening elsewhere.
//   - fuzz.profile_path: the scripts spell its fallback both ways (empty and "unknown").
//   - paths derived from a script's own location ($SCRIPT_DIR/...) or the repo root: they have no
//     fixed literal, and the engine still resolves them itself when the host sends nothing.
//   - run.timeout_sec: no timeout is the honest default, and the key's minimum is 1, so there is
//     no value that means "unbounded".
func Defaults() map[string]string {
	return map[string]string{
		// cluster
		"cluster.bcos_base_port": "20200",
		"cluster.bcos_rpc_url":   "http://127.0.0.1:20200",
		"cluster.contract_name":  "HelloWorld",
		"cluster.fund_amount":    "1000000000000000000",
		"cluster.group_id":       "group0",
		"cluster.node_dir":       "./nodes-release-gate/127.0.0.1",
		"cluster.root":           "./nodes-release-gate",

		// fuzz
		"fuzz.batch":     "100",
		"fuzz.continue":  "0",
		"fuzz.iters":     "20",
		"fuzz.sec":       "0",
		"fuzz.seed":      "42",
		"fuzz.strategy":  "both",
		"fuzz.transport": "bcos",

		// jsd
		"jsd.count": "50",
		"jsd.group": "group0",
		"jsd.qps":   "10",

		// oracles
		"oracle.hang_sec":        "10",
		"oracle.once_wait_sec":   "2",
		"oracle.receipt_timeout": "30",
		"oracle.stall_sec":       "30",

		// tools
		"tools.console_dir": "console/dist",
		"tools.java_bin":    "java",

		// upgrade
		"upgrade.rollback": "0",

		// host-only: cluster_up.sh's own getopts defaults (NODES=4, PORTS="30300,20200",
		// SM_FLAG=""), which no ${NAME:-...} expression can express.
		"cluster.node_count":    "4",
		"cluster.p2p_base_port": "30300",
		"crypto.sm_mode":        "false",
		// gate.sh runs every scenario and aggregates at the end rather than stopping at the first
		// failure, and 1A starts no subprocesses at all.
		"run.fail_fast":      "false",
		"run.allow_parallel": "false",
	}
}
