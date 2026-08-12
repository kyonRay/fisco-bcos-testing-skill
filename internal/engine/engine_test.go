package engine

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/testinstall"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "engine.json")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func manifest(proto, ev, out string) string {
	return `{"engine_protocol_version":"` + proto + `","event_schema_version":"` + ev +
		`","output_schema_version":"` + out + `","capabilities":["gate","cluster"]}`
}

func TestLoadAndCheckAcceptTheShippedShape(t *testing.T) {
	m, err := Load(write(t, manifest("1.0.0", "1.0.0", "1.0.0")))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Check(); err != nil {
		t.Errorf("Check() = %v, want nil", err)
	}
	if !m.Has("gate") || m.Has("nope") {
		t.Error("Has() is wrong")
	}
	if maj, err := m.EventMajor(); err != nil || maj != 1 {
		t.Errorf("EventMajor = %d, %v", maj, err)
	}
}

// Only two of the three versions block; the third is validated but tolerated.
func TestPerFieldVersionPolicy(t *testing.T) {
	for _, c := range []struct {
		name           string
		proto, ev, out string
		wantErr        bool
	}{
		{"protocol major differs", "2.0.0", "1.0.0", "1.0.0", true},
		{"event major differs", "1.0.0", "2.0.0", "1.0.0", true},
		{"output major differs is tolerated", "1.0.0", "1.0.0", "2.0.0", false},
		{"newer minors and patches accepted", "1.7.3", "1.3.9", "1.9.1", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			m, err := Load(write(t, manifest(c.proto, c.ev, c.out)))
			if err != nil {
				t.Fatal(err)
			}
			err = m.Check()
			if c.wantErr {
				if err == nil {
					t.Fatal("want an error")
				}
				if cl, ok := fbterr.ClassOf(err); !ok || cl != fbterr.ClassHost {
					t.Errorf("want ClassHost (exit 40), got %v", cl)
				}
			} else if err != nil {
				t.Errorf("want nil, got %v", err)
			}
		})
	}
}

// Every field must be present and well-formed: a manifest missing one states no contract at all.
func TestCheckRejectsMissingOrMalformedVersions(t *testing.T) {
	for _, b := range []string{
		`{"event_schema_version":"1.0.0","output_schema_version":"1.0.0"}`,
		`{"engine_protocol_version":"1.0.0","output_schema_version":"1.0.0"}`,
		`{"engine_protocol_version":"1.0.0","event_schema_version":"1.0.0"}`,
		manifest("1", "1.0.0", "1.0.0"),
		manifest("1.x.0", "1.0.0", "1.0.0"),
		manifest("v1.0.0", "1.0.0", "1.0.0"),
		manifest("1.0.0", "1.0", "1.0.0"),
		manifest("1.0.0", "1.0.0", ""),
	} {
		m, err := Load(write(t, b))
		if err != nil {
			continue // malformed JSON already rejected at Load
		}
		if err := m.Check(); err == nil {
			t.Errorf("want an error for %s", b)
		}
	}
}

func TestParseSemverIsStrict(t *testing.T) {
	for _, s := range []string{"", "1", "1.0", "1.0.0.0", "1.x.0", "v1.0.0", "-1.0.0", "1.0.0-rc1", " 1.0.0"} {
		if _, _, _, err := ParseSemver(s); err == nil {
			t.Errorf("ParseSemver(%q) = nil error, want strict rejection", s)
		}
	}
	if maj, min, pat, err := ParseSemver("3.16.4"); err != nil || maj != 3 || min != 16 || pat != 4 {
		t.Errorf("ParseSemver(3.16.4) = %d,%d,%d,%v", maj, min, pat, err)
	}
}

// A missing manifest is a broken installation -> infra (30), not a host bug.
func TestMissingManifestIsInfra(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "absent.json"))
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassInfra {
		t.Errorf("want ClassInfra (exit 30), got %v (err=%v)", c, err)
	}
}

// The file exists but its contract is unreadable -> host (40).
func TestMalformedJSONIsHost(t *testing.T) {
	_, err := Load(write(t, `{"engine_protocol_version":`))
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassHost {
		t.Errorf("want ClassHost (exit 40), got %v (err=%v)", c, err)
	}
}

// The shared fixture must satisfy Check, or every downstream test built on it rests on an invalid
// manifest.
func TestFixtureInstallManifestPasses(t *testing.T) {
	ti := testinstall.New(t)
	m, err := Load(filepath.Join(ti.Root, "libexec", "fbt", "engine.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Check(); err != nil {
		t.Errorf("the shared fixture's manifest fails Check(): %v", err)
	}
}

// The REAL engine.json shipped in this repository must also pass, or the host cannot drive the
// engine it ships beside.
func TestRealShippedManifestPasses(t *testing.T) {
	m, err := Load("../../engine.json")
	if err != nil {
		t.Fatalf("the repository's engine.json must be loadable: %v", err)
	}
	if err := m.Check(); err != nil {
		t.Errorf("the repository's engine.json fails Check(): %v", err)
	}
	for _, c := range []string{"gate", "cluster", "case", "fuzz", "upgrade", "ut"} {
		if !m.Has(c) {
			t.Errorf("shipped manifest lost capability %q", c)
		}
	}
}
