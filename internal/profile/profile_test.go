package profile

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// minGenesis is prepended to every fixture: Parse requires [genesis] compatibility_version, so a
// fixture without it would fail on that check instead of on the behaviour under test.
const minGenesis = "[genesis]\ncompatibility_version = 3.16.4\n"

func writeProfile(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "x.profile")
	if err := os.WriteFile(p, []byte(minGenesis+body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReplayPreservesFileOrder(t *testing.T) {
	got, err := Parse(writeProfile(t, `[system_config_replay]
# the chain enforces this dependency chain
feature_balance = 1
feature_balance_precompiled = 1
tx_gas_price = 0x5208

auth_check_status = 1
`))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"feature_balance", "feature_balance_precompiled", "tx_gas_price", "auth_check_status"}
	if len(got.Replay) != len(want) {
		t.Fatalf("Replay = %+v, want %d entries", got.Replay, len(want))
	}
	for i, k := range want {
		if got.Replay[i].Key != k {
			t.Errorf("Replay[%d] = %q, want %q", i, got.Replay[i].Key, k)
		}
	}
}

// Matches profile_lib.sh:75,79 -- first occurrence fixes the position, last assignment wins, and
// the key is emitted exactly once. Appending instead would replay auth_check_status twice, and the
// second call comes back "Permission denied".
func TestDuplicateKeyKeepsFirstPositionAndLastValue(t *testing.T) {
	got, err := Parse(writeProfile(t, `[system_config_replay]
tx_count_limit = 500
feature_balance = 1
tx_count_limit = 1000
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Replay) != 2 {
		t.Fatalf("Replay = %+v, want 2 entries (the duplicate must collapse)", got.Replay)
	}
	if got.Replay[0].Key != "tx_count_limit" || got.Replay[0].Value != "1000" {
		t.Errorf("Replay[0] = %+v, want tx_count_limit keeping its FIRST position with the "+
			"LAST value 1000", got.Replay[0])
	}
}

func TestDuplicateKeyRuleAppliesToConfigINIToo(t *testing.T) {
	got, err := Parse(writeProfile(t, "[config_ini_override]\na.b = 1\nc.d = 2\na.b = 3\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.ConfigINI) != 2 || got.ConfigINI[0].Key != "a.b" || got.ConfigINI[0].Value != "3" {
		t.Errorf("ConfigINI = %+v", got.ConfigINI)
	}
}

// profile_lib.sh:63-64 splits on the FIRST '=' (${line%%=*} / ${line#*=}).
func TestValueMayContainEquals(t *testing.T) {
	got, err := Parse(writeProfile(t, "[system_config_replay]\nk = a=b=c\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got.Replay[0].Value != "a=b=c" {
		t.Errorf("Value = %q, want a=b=c", got.Replay[0].Value)
	}
}

func TestSectionsAreSeparated(t *testing.T) {
	got, err := Parse(writeProfile(t, "[meta]\nsource_chain = wbbc\n[config_ini_override]\nx.y = 1\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got.Meta["source_chain"] != "wbbc" || got.Genesis["compatibility_version"] != "3.16.4" {
		t.Errorf("Meta=%+v Genesis=%+v", got.Meta, got.Genesis)
	}
}

// compatibility_version drives build_chain -v and the whole upgrade path.
func TestMissingCompatibilityVersionIsAConfigError(t *testing.T) {
	p := filepath.Join(t.TempDir(), "y.profile")
	if err := os.WriteFile(p, []byte("[meta]\nsource_chain = x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Parse(p)
	if err == nil {
		t.Fatal("want an error when [genesis] compatibility_version is absent")
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
		t.Errorf("want ClassConfig (exit 20), got %v", c)
	}
}

// profile_lib.sh's `case "$section"` has no default arm, so a typo'd section or a key above the
// first header is silently dropped there. The host refuses instead: a profile that loses half its
// replay list to a typo would otherwise reproduce the wrong chain and still report PASS.
func TestUnknownSectionAndStrayKeyAreErrors(t *testing.T) {
	for _, body := range []string{"[nonsense]\nk = v\n", "stray = 1\n[meta]\n"} {
		p := filepath.Join(t.TempDir(), "z.profile")
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := Parse(p)
		if err == nil {
			t.Errorf("want an error for %q", body)
			continue
		}
		if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
			t.Errorf("%q: want ClassConfig, got %v", body, c)
		}
	}
}

// profile_lib.sh:54 only treats '#' as a comment marker. A ';'-led line still contains '=', so
// bash records it as a key -- the host must not quietly disagree about what the file contains.
func TestSemicolonIsNotACommentMarker(t *testing.T) {
	got, err := Parse(writeProfile(t, "[system_config_replay]\n;k = v\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Replay) != 1 || got.Replay[0].Key != ";k" {
		t.Errorf("Replay = %+v, want the ';k' key bash would record", got.Replay)
	}
}

// A missing file is infra (exit 30 territory via the caller), not a malformed-config error.
func TestUnreadableProfileIsAnInfraError(t *testing.T) {
	_, err := Parse(filepath.Join(t.TempDir(), "absent.profile"))
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassInfra {
		t.Errorf("want ClassInfra, got %v (err=%v)", c, err)
	}
}

// The six shipped profiles are the format's real corpus: if Parse and profile_lib.sh ever drift,
// this is where it shows up first.
func TestParsesEveryShippedProfile(t *testing.T) {
	files, err := filepath.Glob("../../profiles/*.profile")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) < 5 {
		t.Fatalf("found only %d shipped profiles under ../../profiles -- wrong path; this test "+
			"would otherwise pass vacuously", len(files))
	}
	for _, f := range files {
		p, err := Parse(f)
		if err != nil {
			t.Errorf("Parse(%s): %v", f, err)
			continue
		}
		if p.Genesis["compatibility_version"] == "" {
			t.Errorf("%s: compatibility_version empty despite Parse succeeding", f)
		}
	}
}

// production-enterprise is the anchor profile, and its replay order is load-bearing: the balance
// flags have a dependency chain and auth_check_status must come last (see the profile's own
// comments). Pinning it here catches an ordering regression in the parser itself.
func TestAnchorProfileKeepsItsLoadBearingOrder(t *testing.T) {
	p, err := Parse("../../profiles/production-enterprise.profile")
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	for i, kv := range p.Replay {
		pos[kv.Key] = i
	}
	for _, pair := range [][2]string{
		{"feature_balance", "feature_balance_precompiled"},
		{"feature_balance_precompiled", "feature_balance_policy1"},
	} {
		if pos[pair[0]] >= pos[pair[1]] {
			t.Errorf("%s must be replayed before %s", pair[0], pair[1])
		}
	}
	if got := pos["auth_check_status"]; got != len(p.Replay)-1 {
		t.Errorf("auth_check_status is at %d of %d; it must be last, since it locks out every "+
			"further setSystemConfigByKey", got, len(p.Replay))
	}
}
