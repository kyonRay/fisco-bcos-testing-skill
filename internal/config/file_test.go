package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func yamlAt(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "fbt.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadFileFlattensAndStringifies(t *testing.T) {
	got, err := LoadFile(yamlAt(t, t.TempDir(),
		"fuzz:\n  batch: 60\n  transport: web3\nupgrade:\n  rollback: true\n"), false)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{
		"fuzz.batch": "60", "fuzz.transport": "web3", "upgrade.rollback": "true",
	} {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

// An explicitly named missing config is exit 30: treating it as empty makes the user's settings
// vanish without a word, and the run proceeds under defaults it never asked for.
func TestExplicitMissingConfigIsInfraError(t *testing.T) {
	_, err := LoadFile(filepath.Join(t.TempDir(), "absent.yaml"), true)
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassInfra {
		t.Errorf("want ClassInfra (exit 30), got %v (err=%v)", c, err)
	}
}

func TestImplicitMissingConfigIsEmptyAndFine(t *testing.T) {
	got, err := LoadFile(filepath.Join(t.TempDir(), "absent.yaml"), false)
	if err != nil || len(got) != 0 {
		t.Errorf("got %+v, %v; want empty and nil", got, err)
	}
}

func TestEmptyPathAndEmptyFileYieldEmptyConfig(t *testing.T) {
	for _, p := range []string{"", yamlAt(t, t.TempDir(), "")} {
		got, err := LoadFile(p, true)
		if err != nil || len(got) != 0 {
			t.Errorf("LoadFile(%q) = %+v, %v; want empty and nil", p, got, err)
		}
	}
}

func TestUnknownKeyIsRejectedWithItsPath(t *testing.T) {
	_, err := LoadFile(yamlAt(t, t.TempDir(), "fuzz:\n  batchh: 60\n"), false)
	if err == nil || !strings.Contains(err.Error(), "fuzz.batchh") {
		t.Fatalf("want an error naming fuzz.batchh, got %v", err)
	}
	// A typo one edit away should get a suggestion; otherwise the user has to diff the key list.
	if !strings.Contains(err.Error(), "fuzz.batch\"") {
		t.Errorf("want a did-you-mean pointing at fuzz.batch, got %v", err)
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
		t.Errorf("want ClassConfig, got %v", c)
	}
}

func TestValuesAreValidatedAgainstTheRegistry(t *testing.T) {
	for _, b := range []string{
		"fuzz:\n  batch: abc\n",
		"fuzz:\n  batch: 0\n",
		"upgrade:\n  rollback: 42\n",
		"fuzz:\n  transport: nonsense\n",
		"cluster:\n  web3_base_port: 70000\n",
		"run:\n  timeout_sec: abc\n",
	} {
		if _, err := LoadFile(yamlAt(t, t.TempDir(), b), false); err == nil {
			t.Errorf("LoadFile accepted invalid config:\n%s", b)
		}
	}
}

// spec §7.3: a relative path inside fbt.yaml is relative to that file's own directory, so a config
// committed beside a project works no matter where fbt is invoked from.
func TestRelativePathsResolveAgainstTheYAMLDirectory(t *testing.T) {
	dir := t.TempDir()
	got, err := LoadFile(yamlAt(t, dir, "tools:\n  console_dir: ./console\n"), false)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "console"); got["tools.console_dir"] != want {
		t.Errorf("tools.console_dir = %q, want %q", got["tools.console_dir"], want)
	}
}

func TestAbsolutePathsAndNonPathValuesAreLeftAlone(t *testing.T) {
	got, err := LoadFile(yamlAt(t, t.TempDir(),
		"tools:\n  console_dir: /opt/console\ncluster:\n  group_id: group0\n"), false)
	if err != nil {
		t.Fatal(err)
	}
	if got["tools.console_dir"] != "/opt/console" || got["cluster.group_id"] != "group0" {
		t.Errorf("got %+v", got)
	}
}

func TestMalformedYAMLAndNonScalarLeafAreConfigErrors(t *testing.T) {
	for _, b := range []string{"fuzz:\n  batch: [unclosed\n", "fuzz:\n  batch:\n    - 1\n"} {
		_, err := LoadFile(yamlAt(t, t.TempDir(), b), false)
		if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
			t.Errorf("want ClassConfig for %q, got %v (err=%v)", b, c, err)
		}
	}
}

// `fuzz:\n  batch:\n` parses as an explicit null. Dropping it silently would mean a user who
// deleted a value by accident gets the default with no word about it -- while a whole empty
// document (root null) is legitimately empty.
func TestExplicitNullLeafIsAConfigErrorButAnEmptyDocumentIsNot(t *testing.T) {
	_, err := LoadFile(yamlAt(t, t.TempDir(), "fuzz:\n  batch:\n"), false)
	if err == nil || !strings.Contains(err.Error(), "fuzz.batch") {
		t.Errorf("want an error naming fuzz.batch, got %v", err)
	}
	if got, err := LoadFile(yamlAt(t, t.TempDir(), "# only a comment\n"), false); err != nil || len(got) != 0 {
		t.Errorf("a comment-only document = %+v, %v; want empty and nil", got, err)
	}
}

// The dotted key is built from the nesting, so a two-level path and a literal dotted key must not
// be distinguishable downstream -- config_ini_override keys like web3_rpc.listen_port arrive in
// the literal form.
func TestDeepNestingAndScalarKindsAllStringify(t *testing.T) {
	got, err := LoadFile(yamlAt(t, t.TempDir(),
		"fuzz:\n  seed: -1\n  continue: false\noracle:\n  once_wait_sec: 0\n"), false)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{
		"fuzz.seed": "-1", "fuzz.continue": "false", "oracle.once_wait_sec": "0",
	} {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}
