package keys

import (
	"sort"
	"strings"
	"testing"
)

func envMap(t *testing.T, kv []string) map[string]string {
	t.Helper()
	m := map[string]string{}
	for _, e := range kv {
		i := strings.IndexByte(e, '=')
		if i < 0 {
			t.Fatalf("malformed env entry %q", e)
		}
		m[e[:i]] = e[i+1:]
	}
	return m
}

// One config key fans out to BOTH names: dual_rpc reads WEB3_RPC_URL, the fuzz driver reads
// RG_FUZZ_WEB3_URL. Injecting only one aims the two at different nodes.
func TestTranslateWeb3URLFansOutToBothNames(t *testing.T) {
	kv, err := Translate(map[string]string{"cluster.web3_rpc_url": "http://127.0.0.1:9545"})
	if err != nil {
		t.Fatal(err)
	}
	got := envMap(t, kv)
	if got["WEB3_RPC_URL"] != "http://127.0.0.1:9545" || got["RG_FUZZ_WEB3_URL"] != "http://127.0.0.1:9545" {
		t.Errorf("want both names set, got %q / %q", got["WEB3_RPC_URL"], got["RG_FUZZ_WEB3_URL"])
	}
}

func TestTranslateFuzzJarExportsLegacyAliasToo(t *testing.T) {
	kv, err := Translate(map[string]string{"tools.fuzz_jar": "/opt/f.jar"})
	if err != nil {
		t.Fatal(err)
	}
	got := envMap(t, kv)
	if got["FUZZ_JAR"] != "/opt/f.jar" || got["TAMPER_FUZZ_JAR"] != "/opt/f.jar" {
		t.Errorf("got %q / %q", got["FUZZ_JAR"], got["TAMPER_FUZZ_JAR"])
	}
}

// Host-only keys never reach the engine.
func TestTranslateSkipsHostOnlyKeys(t *testing.T) {
	kv, err := Translate(map[string]string{"run.fail_fast": "true", "fuzz.batch": "60"})
	if err != nil {
		t.Fatal(err)
	}
	got := envMap(t, kv)
	if got["RG_FUZZ_BATCH"] != "60" {
		t.Errorf("fuzz.batch did not translate: %+v", got)
	}
	if len(got) != 1 {
		t.Errorf("a host-only key leaked into the engine environment: %+v", got)
	}
}

func TestTranslateRejectsUnknownKey(t *testing.T) {
	_, err := Translate(map[string]string{"fuzz.batchh": "200"})
	if err == nil || !strings.Contains(err.Error(), "fuzz.batchh") {
		t.Fatalf("want an error naming the unknown key, got %v", err)
	}
}

func TestTranslateValidatesValues(t *testing.T) {
	if _, err := Translate(map[string]string{"fuzz.batch": "abc"}); err == nil {
		t.Error("Translate must not pass an invalid value through to the engine")
	}
}

// ---- the false-green guard (spec §7.5) -------------------------------------

func TestStripListCoversEveryScriptSubstitutionHook(t *testing.T) {
	for _, e := range []string{"STATEROOT_ORACLE", "CLUSTER_UP", "_SELF_DIR",
		"SCENARIO_UT_SELF_DIR", "SCENARIO_DRY"} {
		if !IsStripped(e) {
			t.Errorf("IsStripped(%q) = false: an inherited value here substitutes a script or "+
				"skips the work entirely", e)
		}
		if StripReason(e) == "" {
			t.Errorf("%s has no recorded reason; the reason is what stops it being deleted later", e)
		}
	}
}

// SCENARIO_DRY gets its own test: it is the one that turns a whole gate run into a no-op which
// still exits 0.
func TestScenarioDryIsStrippedAndUnbindable(t *testing.T) {
	if !IsStripped("SCENARIO_DRY") {
		t.Fatal("SCENARIO_DRY must be stripped from the inherited environment")
	}
	for _, r := range Rows() {
		for _, e := range r.Env {
			if e == "SCENARIO_DRY" {
				t.Fatalf("config key %q must not bind SCENARIO_DRY", r.Key)
			}
		}
	}
}

// APPLY_PROFILE is assigned unconditionally by gate.sh:167, so env cannot override it. Listing it
// would imply a hazard that does not exist; this pins the corrected understanding.
func TestApplyProfileIsNotOnTheStripList(t *testing.T) {
	if IsStripped("APPLY_PROFILE") {
		t.Error("APPLY_PROFILE is not env-overridable (gate.sh:167 assigns it unconditionally)")
	}
}

// ---- reverse direction (spec §7.6) -----------------------------------------

func TestFromLegacyEnvMapsBackToCanonicalKeys(t *testing.T) {
	got := FromLegacyEnv(map[string]string{
		"RG_FUZZ_BATCH":    "60",
		"WEB3_PRIVATE_KEY": "0xdead",
		"PATH":             "/usr/bin",
	})
	if got["fuzz.batch"] != "60" || got["tools.web3_private_key"] != "0xdead" {
		t.Errorf("got %+v", got)
	}
	if len(got) != 2 {
		t.Errorf("unrelated environment must be ignored, got %+v", got)
	}
}

func TestFromLegacyEnvPrimaryBeatsAlias(t *testing.T) {
	got := FromLegacyEnv(map[string]string{"FUZZ_JAR": "/new.jar", "TAMPER_FUZZ_JAR": "/old.jar"})
	if got["tools.fuzz_jar"] != "/new.jar" {
		t.Errorf("got %q, want the primary name to win", got["tools.fuzz_jar"])
	}
}

func TestFromLegacyEnvIgnoresStrippedNames(t *testing.T) {
	got := FromLegacyEnv(map[string]string{"SCENARIO_DRY": "1", "STATEROOT_ORACLE": "/tmp/x"})
	if len(got) != 0 {
		t.Errorf("stripped names leaked into config: %+v", got)
	}
}

// ---- validation ------------------------------------------------------------

func TestValidateRejectsBadTypesEnumsAndRanges(t *testing.T) {
	for _, c := range []struct{ key, val, why string }{
		{"fuzz.batch", "abc", "not an integer"},
		{"fuzz.batch", "0", "below minimum"},
		{"upgrade.rollback", "42", "not a boolean"},
		{"fuzz.transport", "nonsense", "not in the enum"},
		{"fuzz.strategy", "wild", "not in the enum"},
		{"cluster.web3_base_port", "0", "port below 1"},
		{"cluster.web3_base_port", "70000", "port above 65535"},
		{"run.timeout_sec", "abc", "host-only keys are typed too"},
	} {
		if err := Validate(c.key, c.val); err == nil {
			t.Errorf("Validate(%q, %q) = nil, want an error (%s)", c.key, c.val, c.why)
		}
	}
	for _, c := range []struct{ key, val string }{
		{"fuzz.batch", "60"},
		{"upgrade.rollback", "true"},
		{"fuzz.transport", "web3method"},
		{"fuzz.strategy", "both"},
		{"cluster.web3_base_port", "9545"},
		{"tools.console_dir", "/anything/goes"},
		{"run.timeout_sec", "600"},
		{"fuzz.seed", "-5"},
	} {
		if err := Validate(c.key, c.val); err != nil {
			t.Errorf("Validate(%q, %q) = %v, want nil", c.key, c.val, err)
		}
	}
}

// ---- table hygiene ---------------------------------------------------------

func TestTableIsWellFormedAndSorted(t *testing.T) {
	seenKey := map[string]bool{}
	seenEnv := map[string]string{}
	for _, r := range Rows() {
		if r.Key == "" {
			t.Errorf("row %+v has an empty key", r)
		}
		if r.Domain == DomainRunEnv && len(r.Env) == 0 {
			t.Errorf("row %q is a run-env key with no env names", r.Key)
		}
		if r.Domain == DomainHost && len(r.Env) != 0 {
			t.Errorf("row %q is host-only but binds env %v", r.Key, r.Env)
		}
		if seenKey[r.Key] {
			t.Errorf("duplicate config key %q", r.Key)
		}
		seenKey[r.Key] = true
		for _, e := range r.Env {
			if prev, dup := seenEnv[e]; dup {
				t.Errorf("env %s bound by both %q and %q", e, prev, r.Key)
			}
			seenEnv[e] = r.Key
			if IsStripped(e) {
				t.Errorf("row %q binds stripped env %s", r.Key, e)
			}
		}
		if r.Type == KindEnum && len(r.Enum) == 0 {
			t.Errorf("row %q is KindEnum with an empty Enum list", r.Key)
		}
	}
	rows := Rows()
	if !sort.SliceIsSorted(rows, func(i, j int) bool { return rows[i].Key < rows[j].Key }) {
		t.Error("Rows() must be sorted so `config show` output is stable")
	}
}

// spec §7.7: the keys the spec names must all exist, or a legal config is rejected as unknown.
func TestSpecMandatedKeysExist(t *testing.T) {
	for _, k := range []string{
		"repo.root", "cluster.node_count", "cluster.p2p_base_port", "crypto.sm_mode",
		"tools.tamper_block_limit", "cluster.contract_name",
		"fuzz.profile_path", "fuzz.profile_name",
		"engine.scripts_dir", "engine.profile_dir", "engine.state_cases",
	} {
		if !IsKnown(k) {
			t.Errorf("spec-mandated key %q is missing from the registry", k)
		}
	}
}

// A range that rejects the engine's own default makes a working mode unreachable from
// configuration. fuzz.sec=0 is fuzz_bcos.sh:72-73's documented "use the iteration budget instead".
func TestRangesAcceptTheEnginesOwnDefaults(t *testing.T) {
	for _, c := range []struct{ key, val string }{
		{"fuzz.sec", "0"},
		{"fuzz.continue", "0"},
		{"oracle.once_wait_sec", "0"},
		{"fuzz.seed", "42"},
		{"tools.tamper_block_limit", "0"},
	} {
		if err := Validate(c.key, c.val); err != nil {
			t.Errorf("Validate(%s, %q): %v", c.key, c.val, err)
		}
	}
}

// Every command name a row claims must be one fbt actually has, or `config show --command gate`
// silently omits a key some typo'd name was guarding.
func TestRowCommandsAreAllRealCommands(t *testing.T) {
	tagged := 0
	for _, r := range Rows() {
		for _, c := range r.Commands {
			if !IsKnownCommand(c) {
				t.Errorf("%s claims command %q, which fbt does not have", r.Key, c)
			}
		}
		if len(r.Commands) > 0 {
			tagged++
		}
	}
	if tagged < 30 {
		t.Fatalf("only %d rows carry a command surface -- the column is barely filled in", tagged)
	}
}

// A key with no command list is needed everywhere; a filtered view that dropped those would tell
// the user the engine runs without a repo root.
func TestRowsForCommandKeepsUniversalKeysAndDropsForeignOnes(t *testing.T) {
	has := func(rows []Row, key string) bool {
		for _, r := range rows {
			if r.Key == key {
				return true
			}
		}
		return false
	}
	gate := RowsForCommand("gate")
	for _, k := range []string{"repo.root", "engine.scripts_dir", "cluster.group_id", "jsd.qps",
		"oracle.stall_sec", "tools.web3_private_key"} {
		if !has(gate, k) {
			t.Errorf("gate's surface is missing %q", k)
		}
	}
	for _, k := range []string{"fuzz.seed", "crypto.sm_mode"} {
		if has(gate, k) {
			t.Errorf("%q is not part of gate's surface", k)
		}
	}
	if len(RowsForCommand("gate")) >= len(Rows()) {
		t.Error("filtering by command returned everything -- the filter is not filtering")
	}
	// Every known command must yield a usable surface, not an empty one.
	for _, c := range KnownCommands() {
		if len(RowsForCommand(c)) == 0 {
			t.Errorf("command %q has an empty key surface", c)
		}
	}
}
