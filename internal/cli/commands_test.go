package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/testinstall"
)

// fixture returns the flags that point fbt at a throwaway install. The real command table is used
// here, not a probe: these tests are the only place the wiring between dispatch, paths, config and
// profile is exercised end to end.
func fixture(t *testing.T, extra ...string) (testinstall.Install, []string) {
	t.Helper()
	ti := testinstall.New(t)
	// A real, empty fbt.yaml: an explicitly named file that does NOT exist is exit 30 (spec §5),
	// which would fail every test here for the wrong reason.
	base := []string{"--engine-dir", ti.Root, "--state-dir", ti.State,
		"--config", ti.WriteConfig(t, "")}
	return ti, append(base, extra...)
}

func runReal(t *testing.T, argv ...string) (exitcode.Code, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := dispatch(context.Background(), commands, argv, &out, &errOut)
	return code, out.String(), errOut.String()
}

func decode(t *testing.T, s string) map[string]interface{} {
	t.Helper()
	var doc map[string]interface{}
	if err := json.Unmarshal([]byte(s), &doc); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, s)
	}
	return doc
}

// Only implemented commands are registered. A placeholder that answers nothing would still appear
// in `fbt --help` and in shell completion, promising a command that does not exist.
func TestRealTableRegistersOnlyImplementedCommands(t *testing.T) {
	want := map[string]bool{
		"config": true, "profile": true, "doctor": true, "plan": true,
		"case": true, "cluster": true, "gate": true, "fuzz": true, "upgrade": true,
	}
	for name := range commands {
		if !want[name] {
			t.Errorf("command %q is registered but is not in the implemented set", name)
		}
	}
	for name := range want {
		if _, ok := commands[name]; !ok {
			t.Errorf("command %q is missing from the table", name)
		}
	}
}

func TestConfigPathReportsTheInstallLayout(t *testing.T) {
	ti, flags := fixture(t)
	code, out, _ := runReal(t, append([]string{"--output", "json"}, append(flags, "config", "path")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v", code)
	}
	doc := decode(t, out)
	for key, want := range map[string]string{
		"scripts":       filepath.Join(ti.Root, "libexec", "fbt", "scripts"),
		"profiles":      filepath.Join(ti.Root, "share", "fbt", "profiles"),
		"shipped_cases": filepath.Join(ti.Root, "share", "fbt", "cases"),
		"state_cases":   filepath.Join(ti.State, "cases"),
	} {
		if doc[key] != want {
			t.Errorf("%s = %v, want %v", key, doc[key], want)
		}
	}
}

// spec §6.3: "final configuration" means all five layers, not the contents of the config file.
func TestConfigShowWiresAllFiveLayers(t *testing.T) {
	ti, _ := fixture(t)
	cfg := ti.WriteConfig(t, "fuzz:\n  batch: 200\njsd:\n  qps: 25\n")
	t.Setenv("RG_FUZZ_ITERS", "77") // the env layer, above fbt.yaml

	code, out, _ := runReal(t, "--output", "json", "--engine-dir", ti.Root, "--state-dir", ti.State,
		"--config", cfg, "config", "show", "-p", "production-enterprise")
	if code != exitcode.OK {
		t.Fatalf("code = %v\n%s", code, out)
	}
	got := map[string][2]string{}
	for _, raw := range decode(t, out)["keys"].([]interface{}) {
		m := raw.(map[string]interface{})
		got[m["key"].(string)] = [2]string{m["value"].(string), m["source"].(string)}
	}
	for key, want := range map[string][2]string{
		"fuzz.seed":                     {"42", "default"},     // built-in default layer
		"genesis.compatibility_version": {"3.16.4", "profile"}, // profile layer
		"cluster.web3_base_port":        {"8545", "profile"},   // profile's [config_ini_override]
		"fuzz.batch":                    {"200", "fbt.yaml"},   // file layer
		"jsd.qps":                       {"25", "fbt.yaml"},
		"fuzz.iters":                    {"77", "env"}, // env layer
		"engine.profile_dir":            {filepath.Join(ti.Root, "share", "fbt", "profiles"), "flag"},
	} {
		if got[key] != want {
			t.Errorf("%s = %v, want %v", key, got[key], want)
		}
	}
}

// The secret must not appear on ANY output path; a partial key is still the key.
func TestPrivateKeyIsRedactedInEveryOutputMode(t *testing.T) {
	const secret = "0xdeadbeefcafebabe0123456789abcdef0123456789abcdef0123456789abcdef"
	ti, _ := fixture(t)
	cfg := ti.WriteConfig(t, "tools:\n  web3_private_key: "+secret+"\n")

	for _, mode := range []string{"human", "json", "jsonl"} {
		code, out, errOut := runReal(t, "--output", mode, "--engine-dir", ti.Root,
			"--state-dir", ti.State, "--config", cfg, "config", "show")
		if code != exitcode.OK {
			t.Fatalf("%s: code = %v\n%s%s", mode, code, out, errOut)
		}
		if strings.Contains(out+errOut, secret) {
			t.Errorf("%s: the private key was printed in full", mode)
		}
		for _, frag := range []string{secret[:10], secret[len(secret)-10:]} {
			if strings.Contains(out+errOut, frag) {
				t.Errorf("%s: a fragment of the private key leaked (%q)", mode, frag)
			}
		}
		if !strings.Contains(out, redacted) {
			t.Errorf("%s: the key should still be listed, redacted; got %q", mode, out)
		}
	}
}

func TestConfigShowCommandFilterAndAllKeys(t *testing.T) {
	_, flags := fixture(t)
	list := func(args ...string) map[string]bool {
		t.Helper()
		code, out, errOut := runReal(t, append([]string{"--output", "json"}, append(flags, args...)...)...)
		if code != exitcode.OK {
			t.Fatalf("code = %v\n%s%s", code, out, errOut)
		}
		got := map[string]bool{}
		for _, raw := range decode(t, out)["keys"].([]interface{}) {
			got[raw.(map[string]interface{})["key"].(string)] = true
		}
		return got
	}

	gate := list("config", "show", "--command", "gate")
	if gate["fuzz.seed"] {
		t.Error("fuzz.seed is not part of gate's dependency surface")
	}
	if !gate["cluster.group_id"] {
		t.Error("a key needed by every command must survive the filter")
	}

	// --all-keys must list keys with no value, or the "run config show --all-keys" advice printed
	// by the unknown-key error is a dead end.
	all := list("config", "show", "--all-keys")
	set := list("config", "show")
	if len(all) <= len(set) {
		t.Errorf("--all-keys listed %d keys, no more than the %d that have values", len(all), len(set))
	}
	if !all["cluster.fund_addresses"] {
		t.Error("--all-keys omitted a key that has no default and no value")
	}

	if code, _, _ := runReal(t, append(flags, "config", "show", "--command", "banana")...); code != exitcode.Config {
		t.Errorf("--command banana = %v, want 20", code)
	}
}

// filepath.Glob returns no error for a missing directory, so without an explicit stat a broken
// installation prints an empty list and exits 0 -- a false green about the one thing this command
// reports.
func TestProfileListRefusesAMissingProfileDirectory(t *testing.T) {
	broken := t.TempDir()
	code, _, errOut := runReal(t, "--engine-dir", broken, "--state-dir", filepath.Join(broken, "s"),
		"--config", filepath.Join(broken, "absent.yaml"), "profile", "list")
	if code != exitcode.Infra {
		t.Errorf("code = %v, want 30", code)
	}
	if !strings.Contains(errOut, "profile directory") {
		t.Errorf("the error should name the missing directory, got %q", errOut)
	}
}

func TestProfileListEnumeratesTheInstalledProfiles(t *testing.T) {
	_, flags := fixture(t)
	code, out, _ := runReal(t, append([]string{"--output", "json"}, append(flags, "profile", "list")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v", code)
	}
	var names []string
	for _, raw := range decode(t, out)["profiles"].([]interface{}) {
		names = append(names, raw.(map[string]interface{})["name"].(string))
	}
	if len(names) != 2 || names[0] != "default-latest" || names[1] != "production-enterprise" {
		t.Errorf("profiles = %v, want the two fixture profiles in sorted order", names)
	}
}

// Replay order is the correctness property, not a cosmetic one: auth_check_status locks out every
// setSystemConfigByKey that follows it, so a sorted view would misreport what the run will do.
func TestProfileShowKeepsReplayInFileOrder(t *testing.T) {
	ti, flags := fixture(t)
	ti.WriteProfile(t, "ordered", `[genesis]
compatibility_version = 3.16.4
[system_config_replay]
zzz_last = 1
feature_balance = 1
auth_check_status = 1
`)
	code, out, _ := runReal(t, append([]string{"--output", "json"},
		append(flags, "profile", "show", "ordered")...)...)
	if code != exitcode.OK {
		t.Fatalf("code = %v\n%s", code, out)
	}
	var got []string
	for _, raw := range decode(t, out)["system_config_replay"].([]interface{}) {
		got = append(got, raw.(map[string]interface{})["key"].(string))
	}
	want := []string{"zzz_last", "feature_balance", "auth_check_status"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("replay = %v, want file order %v", got, want)
	}
}

func TestProfileShowHumanOutputKeepsReplayOrderToo(t *testing.T) {
	ti, flags := fixture(t)
	ti.WriteProfile(t, "ordered", `[genesis]
compatibility_version = 3.16.4
[system_config_replay]
zzz_last = 1
feature_balance = 1
`)
	_, out, _ := runReal(t, append(flags, "profile", "show", "ordered")...)
	if strings.Index(out, "zzz_last") > strings.Index(out, "feature_balance") {
		t.Errorf("the human view sorted the replay section:\n%s", out)
	}
}

func TestSubcommandErrorsAreUsageErrors(t *testing.T) {
	_, flags := fixture(t)
	for _, args := range [][]string{
		{"config"},
		{"config", "nonesuch"},
		{"profile"},
		{"profile", "nonesuch"},
		{"profile", "show"},
		{"profile", "show", "a", "b"},
		{"profile", "list", "extra"},
		{"profile", "show", "no-such-profile"},
	} {
		code, _, _ := runReal(t, append(append([]string{}, flags...), args...)...)
		if code != exitcode.Config {
			t.Errorf("%v = %v, want 20", args, code)
		}
	}
}

// spec §5: an explicitly named config file that does not exist is 30, not an empty config.
func TestExplicitMissingConfigSurfacesAsInfra(t *testing.T) {
	ti := testinstall.New(t)
	code, _, _ := runReal(t, "--engine-dir", ti.Root, "--state-dir", ti.State,
		"--config", filepath.Join(ti.Root, "absent.yaml"), "config", "show")
	if code != exitcode.Infra {
		t.Errorf("code = %v, want 30", code)
	}
}

// A global flag placed after the subcommand must work, since that is what people type.
func TestGlobalFlagAfterSubcommandIsHonoured(t *testing.T) {
	ti := testinstall.New(t)
	code, out, _ := runReal(t, "config", "path", "--output", "json",
		"--engine-dir", ti.Root, "--state-dir", ti.State,
		"--config", filepath.Join(ti.Root, "fbt.yaml"))
	if code != exitcode.OK {
		t.Fatalf("code = %v\n%s", code, out)
	}
	if decode(t, out)["install_root"] != ti.Root {
		t.Errorf("install_root = %v, want %v", decode(t, out)["install_root"], ti.Root)
	}
}
