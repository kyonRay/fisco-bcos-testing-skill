// Package keys is the single place in fbt that knows an engine environment-variable name. It
// holds the config-key registry with enough metadata to validate values, translate them into the
// engine's environment, map legacy environment back into canonical keys, and refuse the variables
// that would let configuration substitute the engine's own scripts.
package keys

import (
	"sort"
	"strconv"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

type Kind int

const (
	KindString Kind = iota
	KindInt
	KindBool
	KindEnum
	KindPath // string, but resolved relative to the file that declared it (config.LoadFile)
)

type Domain int

const (
	DomainRunEnv Domain = iota // injected into the engine's environment
	DomainHost                 // consumed by the Go host only; Env is empty
)

type Row struct {
	Key    string
	Env    []string // names to export; EMPTY for host-only keys (spec §7.7)
	Legacy []string // additional names accepted as INPUT only, folded into Env by init()
	Type   Kind
	Enum   []string
	Min    *int
	Max    *int
	Secret bool
	Domain Domain
	// Commands are the fbt commands whose dependency surface includes this key (spec §7.4's
	// fourth column). EMPTY means every command -- the repo root and the engine script directory
	// are needed by anything that starts the engine at all. The spec's column names scenario
	// families (dual_rpc, malformed, jsd, ut); those fold into `gate`, which is the command that
	// runs them.
	Commands []string
}

// KnownCommands is the vocabulary `config show --command` and `doctor --command` accept. A name
// outside it is a usage error rather than a filter that silently matches nothing.
func KnownCommands() []string {
	return []string{"case", "cluster", "config", "doctor", "fuzz", "gate", "profile"}
}

func IsKnownCommand(cmd string) bool {
	for _, c := range KnownCommands() {
		if c == cmd {
			return true
		}
	}
	return false
}

// RowsForCommand narrows the registry to the keys that command actually consumes.
func RowsForCommand(cmd string) []Row {
	out := make([]Row, 0, len(table))
	for _, r := range table {
		if len(r.Commands) == 0 {
			out = append(out, r) // needed everywhere
			continue
		}
		for _, c := range r.Commands {
			if c == cmd {
				out = append(out, r)
				break
			}
		}
	}
	return out
}

func intp(v int) *int { return &v }

// stripped are engine variables whose value substitutes WHICH SCRIPT RUNS, or whether the script
// does any work at all. They exist so the bash unit tests can inject a spy. Inherited from the
// host environment they are a false-green vector -- a leftover SCENARIO_DRY=1 in a developer's
// shell turns every subsequent gate run into a no-op that still exits 0 (spec §7.5). They are
// never bound to a config key, never accepted as input, and must be REMOVED from the environment
// handed to the engine (sub-project 1B performs the removal; this list is the authority).
//
// APPLY_PROFILE is deliberately absent: gate.sh:167 assigns it unconditionally, so the
// environment cannot override it, and listing it would imply a hazard that does not exist.
var stripped = map[string]string{
	"STATEROOT_ORACLE":     "oracle_lib.sh:153 - bash \"${STATEROOT_ORACLE:-...}\" picks the stateroot oracle",
	"CLUSTER_UP":           "apply_profile.sh:174 guard, :190 executes it - picks the cluster bring-up script",
	"_SELF_DIR":            "apply_profile.sh:43 - moves _resolve_engine_script's search origin",
	"SCENARIO_UT_SELF_DIR": "scenario_ut.sh:26 - same, for run_ut.sh resolution",
	"SCENARIO_DRY":         "scenario_dual_rpc.sh:375 - scenario prints a plan and returns 0 doing no work",
}

func IsStripped(env string) bool { _, ok := stripped[env]; return ok }

// StripReason explains why a name is stripped, so an error message can be specific.
func StripReason(env string) string { return stripped[env] }

func MustStrip() []string {
	out := make([]string, 0, len(stripped))
	for k := range stripped {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// table is derived from an actual scan of the engine (see exhaustive_test.go): variables READ
// from the environment as ${VAR:-...} across scripts/, tools/ and the sibling checkout, minus the
// ones the scripts assign themselves.
var table = []Row{
	// ---- cluster ----
	{Key: "cluster.bcos_base_port", Env: []string{"BCOS_RPC_BASE_PORT"}, Type: KindInt, Min: intp(1), Max: intp(65535), Commands: []string{"cluster", "doctor"}},
	{Key: "cluster.bcos_rpc_url", Env: []string{"BCOS_RPC_URL"}, Type: KindString, Commands: []string{"case", "fuzz", "gate"}},
	{Key: "cluster.contract_name", Env: []string{"BCOS_CONTRACT_NAME"}, Type: KindString, Commands: []string{"gate"}},
	{Key: "cluster.fund_addresses", Env: []string{"RG_FUND_ADDRESSES"}, Type: KindString, Commands: []string{"cluster"}},
	{Key: "cluster.fund_amount", Env: []string{"RG_FUND_AMOUNT"}, Type: KindString, Commands: []string{"cluster"}},
	{Key: "cluster.group_id", Env: []string{"BCOS_GROUP_ID"}, Type: KindString},
	{Key: "cluster.node_dir", Env: []string{"NODE_DIR"}, Type: KindPath},
	{Key: "cluster.root", Env: []string{"RG_CLUSTER_DIR"}, Type: KindPath, Commands: []string{"cluster", "gate"}},
	{Key: "cluster.web3_base_port", Env: []string{"WEB3_BASE"}, Type: KindInt, Min: intp(1), Max: intp(65535), Commands: []string{"cluster", "doctor"}},
	// One key, two names: dual_rpc reads WEB3_RPC_URL, the fuzz driver reads RG_FUZZ_WEB3_URL.
	// Injecting only one aims the two at different nodes.
	{Key: "cluster.web3_rpc_url", Env: []string{"WEB3_RPC_URL", "RG_FUZZ_WEB3_URL"}, Type: KindString, Commands: []string{"fuzz", "gate"}},
	// Host-only: shapes cluster_up's argv rather than the engine's environment (spec §7.7).
	{Key: "cluster.node_count", Domain: DomainHost, Type: KindInt, Min: intp(1), Commands: []string{"cluster", "gate"}},
	{Key: "cluster.p2p_base_port", Domain: DomainHost, Type: KindInt, Min: intp(1), Max: intp(65535), Commands: []string{"cluster", "doctor"}},
	{Key: "crypto.sm_mode", Domain: DomainHost, Type: KindBool, Commands: []string{"cluster"}},

	// ---- engine relocation (sub-project 0) ----
	{Key: "engine.profile_dir", Env: []string{"FBT_PROFILE_DIR"}, Type: KindPath, Commands: []string{"case", "fuzz"}},
	{Key: "engine.scripts_dir", Env: []string{"FBT_ENGINE_SCRIPTS"}, Type: KindPath},
	{Key: "engine.state_cases", Env: []string{"FBT_STATE_CASES"}, Type: KindPath, Commands: []string{"fuzz"}},

	// ---- fuzz ----
	{Key: "fuzz.batch", Env: []string{"RG_FUZZ_BATCH"}, Type: KindInt, Min: intp(1), Commands: []string{"fuzz"}},
	{Key: "fuzz.continue", Env: []string{"RG_FUZZ_CONTINUE"}, Type: KindBool, Commands: []string{"fuzz"}},
	{Key: "fuzz.iters", Env: []string{"RG_FUZZ_ITERS"}, Type: KindInt, Min: intp(1), Commands: []string{"fuzz"}},
	{Key: "fuzz.profile_name", Env: []string{"RG_FUZZ_PROFILE_NAME"}, Type: KindString, Commands: []string{"fuzz"}},
	{Key: "fuzz.profile_path", Env: []string{"RG_FUZZ_PROFILE"}, Type: KindPath, Commands: []string{"fuzz"}},
	{Key: "fuzz.restart_cmd", Env: []string{"RG_FUZZ_RESTART_CMD"}, Type: KindString, Commands: []string{"fuzz"}},
	// Min 0, not 1: fuzz_bcos.sh:72-73 documents 0 as "no wall-clock budget, use RG_FUZZ_ITERS
	// instead", and 0 is the script's own default. A floor of 1 would reject the engine's default
	// and leave the iteration-budget mode inexpressible from configuration.
	{Key: "fuzz.sec", Env: []string{"RG_FUZZ_SEC"}, Type: KindInt, Min: intp(0), Commands: []string{"fuzz"}},
	{Key: "fuzz.seed", Env: []string{"RG_FUZZ_SEED"}, Type: KindInt, Commands: []string{"fuzz"}},
	{Key: "fuzz.strategy", Env: []string{"RG_FUZZ_STRATEGY"}, Type: KindEnum, Enum: []string{"struct", "bytes", "both"}, Commands: []string{"fuzz"}},
	{Key: "fuzz.transport", Env: []string{"RG_FUZZ_TRANSPORT"}, Type: KindEnum, Enum: []string{"bcos", "web3", "web3method"}, Commands: []string{"fuzz"}},

	// ---- jsd ----
	{Key: "jsd.count", Env: []string{"JSD_COUNT"}, Type: KindInt, Min: intp(1), Commands: []string{"gate"}},
	{Key: "jsd.dir", Env: []string{"JSD_DIR"}, Type: KindPath, Commands: []string{"gate"}},
	{Key: "jsd.group", Env: []string{"JSD_GROUP"}, Type: KindString, Commands: []string{"gate"}},
	{Key: "jsd.qps", Env: []string{"JSD_QPS"}, Type: KindInt, Min: intp(1), Commands: []string{"gate"}},

	// ---- oracles ----
	{Key: "oracle.hang_sec", Env: []string{"RG_HANG_SEC"}, Type: KindInt, Min: intp(1), Commands: []string{"fuzz", "gate"}},
	{Key: "oracle.once_wait_sec", Env: []string{"RG_ONCE_WAIT_SEC"}, Type: KindInt, Min: intp(0), Commands: []string{"fuzz", "gate"}},
	{Key: "oracle.receipt_timeout", Env: []string{"RG_WEB3_RECEIPT_WAIT_SEC"}, Type: KindInt, Min: intp(1), Commands: []string{"gate"}},
	{Key: "oracle.stall_sec", Env: []string{"RG_STALL_SEC"}, Type: KindInt, Min: intp(1), Commands: []string{"fuzz", "gate"}},
	{Key: "oracle.stateroot_extra_urls", Env: []string{"RG_FUZZ_STATEROOT_URLS"}, Type: KindString, Commands: []string{"fuzz", "gate"}},

	// ---- repo / tools ----
	{Key: "repo.root", Env: []string{"FBT_REPO_ROOT"}, Type: KindPath},
	{Key: "tools.build_dir", Env: []string{"BUILD_DIR"}, Type: KindPath, Commands: []string{"cluster", "doctor"}},
	{Key: "tools.console_dir", Env: []string{"CONSOLE_DIR"}, Type: KindPath, Commands: []string{"gate"}},
	{Key: "tools.fisco_bin", Env: []string{"FISCO_BIN"}, Type: KindPath, Commands: []string{"cluster", "doctor", "gate"}},
	{Key: "tools.fuzz_jar", Env: []string{"FUZZ_JAR"}, Legacy: []string{"TAMPER_FUZZ_JAR"}, Type: KindPath, Commands: []string{"fuzz", "gate"}},
	{Key: "tools.java_bin", Env: []string{"JAVA_BIN"}, Type: KindPath, Commands: []string{"fuzz", "gate"}},
	{Key: "tools.tamper_block_limit", Env: []string{"TAMPER_BLOCK_LIMIT"}, Type: KindInt, Min: intp(0), Commands: []string{"gate"}},
	{Key: "tools.tamper_helper", Env: []string{"TAMPER_HELPER"}, Type: KindPath, Commands: []string{"gate"}},
	{Key: "tools.web3_private_key", Env: []string{"WEB3_PRIVATE_KEY"}, Type: KindString, Secret: true, Commands: []string{"gate"}},

	// ---- upgrade ----
	{Key: "upgrade.rollback", Env: []string{"UPGRADE_ROLLBACK"}, Type: KindBool, Commands: []string{"gate"}},

	// ---- host-only run controls (spec §7.7): typed here so `run.timeout_sec: abc` is rejected
	// with the same rigour as `fuzz.batch: abc`.
	{Key: "run.allow_parallel", Domain: DomainHost, Type: KindBool},
	{Key: "run.fail_fast", Domain: DomainHost, Type: KindBool},
	{Key: "run.timeout_sec", Domain: DomainHost, Type: KindInt, Min: intp(1)},
}

func init() {
	// Fold input-only aliases into Env once, here, so a row never has to list a name twice: the
	// malformed scenario still reads TAMPER_FUZZ_JAR, so the alias must be exported as well.
	for i := range table {
		table[i].Env = append(table[i].Env, table[i].Legacy...)
	}
	sort.Slice(table, func(i, j int) bool { return table[i].Key < table[j].Key })
}

func Rows() []Row { return table }

func Lookup(key string) (Row, bool) {
	i := sort.Search(len(table), func(i int) bool { return table[i].Key >= key })
	if i < len(table) && table[i].Key == key {
		return table[i], true
	}
	return Row{}, false
}

func IsKnown(key string) bool { _, ok := Lookup(key); return ok }

// Validate checks one value against its row's type, enum and range.
func Validate(key, value string) error {
	r, ok := Lookup(key)
	if !ok {
		return fbterr.Configf("unknown config key %q", key)
	}
	switch r.Type {
	case KindInt:
		n, err := strconv.Atoi(value)
		if err != nil {
			return fbterr.Configf("%s must be an integer, got %q", key, value)
		}
		if r.Min != nil && n < *r.Min {
			return fbterr.Configf("%s must be >= %d, got %d", key, *r.Min, n)
		}
		if r.Max != nil && n > *r.Max {
			return fbterr.Configf("%s must be <= %d, got %d", key, *r.Max, n)
		}
	case KindBool:
		if _, err := strconv.ParseBool(value); err != nil {
			return fbterr.Configf("%s must be a boolean (true/false), got %q", key, value)
		}
	case KindEnum:
		for _, e := range r.Enum {
			if value == e {
				return nil
			}
		}
		return fbterr.Configf("%s must be one of %v, got %q", key, r.Enum, value)
	}
	return nil
}

// Translate turns canonical config into the environment the engine receives. Host-only keys have
// no Env and are skipped. Values are validated here too, so no caller can bypass Validate by
// building the map directly.
func Translate(vals map[string]string) ([]string, error) {
	ks := make([]string, 0, len(vals))
	for k := range vals {
		ks = append(ks, k)
	}
	sort.Strings(ks) // deterministic ordering keeps golden fixtures stable
	out := make([]string, 0, len(ks)+2)
	for _, k := range ks {
		r, ok := Lookup(k)
		if !ok {
			return nil, fbterr.Configf("unknown config key %q (no engine binding); "+
				"run `fbt config show --all-keys` for the full key list", k)
		}
		if err := Validate(k, vals[k]); err != nil {
			return nil, err
		}
		for _, e := range r.Env {
			if IsStripped(e) {
				return nil, fbterr.Configf("config key %q maps to %s, a test-only engine hook "+
					"that cannot be set from configuration (%s)", k, e, StripReason(e))
			}
			out = append(out, e+"="+vals[k])
		}
	}
	return out, nil
}

// FromLegacyEnv is the INPUT direction (spec §7.6): it reads the process environment and produces
// canonical keys so the environment can act as a configuration layer. Names the table does not
// bind, and every stripped name, are ignored rather than becoming configuration.
func FromLegacyEnv(env map[string]string) map[string]string {
	out := map[string]string{}
	for _, r := range table {
		// Env is primary-first, so the primary name wins over a legacy alias when both are set.
		for _, name := range r.Env {
			if IsStripped(name) {
				continue
			}
			if v, ok := env[name]; ok {
				if _, already := out[r.Key]; !already {
					out[r.Key] = v
				}
			}
		}
	}
	return out
}
