package profile

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func touch(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestResolveBareNameFindsItInProfileDirs(t *testing.T) {
	d := t.TempDir()
	want := touch(t, d, "sm-gov.profile")
	got, err := Resolve("sm-gov", []string{d}, "/cwd")
	if err != nil || got != want {
		t.Errorf("got %q, %v", got, err)
	}
}

// spec §7.3: a path spec is relative to baseDir (the launch cwd the host injects), not to whatever
// directory the process happens to be in when Resolve runs.
func TestResolvePathSpecIsRelativeToBaseDir(t *testing.T) {
	base := t.TempDir()
	sub := filepath.Join(base, "p")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	touch(t, sub, "a.profile")
	got, err := Resolve("p/a.profile", nil, base)
	if err != nil || got != filepath.Join(sub, "a.profile") {
		t.Errorf("got %q, %v", got, err)
	}
}

// Picking one silently would make a run irreproducible: the report says "-p dup" and there is no
// way to tell afterwards which chain it reproduced.
func TestResolveAmbiguousNameIsAConfigError(t *testing.T) {
	d1, d2 := t.TempDir(), t.TempDir()
	touch(t, d1, "dup.profile")
	touch(t, d2, "dup.profile")
	_, err := Resolve("dup", []string{d1, d2}, "/cwd")
	if err == nil {
		t.Fatal("want a conflict error")
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
		t.Errorf("want ClassConfig, got %v", c)
	}
}

func TestResolveMissingNameAndEmptySpecAreConfigErrors(t *testing.T) {
	for _, spec := range []string{"nope", ""} {
		_, err := Resolve(spec, []string{t.TempDir()}, "/cwd")
		if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassConfig {
			t.Errorf("Resolve(%q): want ClassConfig, got %v (err=%v)", spec, c, err)
		}
	}
}

func TestResolveAbsolutePathIsUsedAsIs(t *testing.T) {
	p := touch(t, t.TempDir(), "abs.profile")
	got, err := Resolve(p, nil, "/unrelated")
	if err != nil || got != p {
		t.Errorf("got %q, %v", got, err)
	}
}

// The first directory in dirs wins only when the name is unique to it; a name present in exactly
// one of several directories must still resolve, so an empty or missing directory in the list
// cannot make a valid name unresolvable.
func TestResolveSkipsEmptyAndMissingDirs(t *testing.T) {
	d := t.TempDir()
	want := touch(t, d, "only.profile")
	got, err := Resolve("only", []string{"", filepath.Join(t.TempDir(), "gone"), d}, "/cwd")
	if err != nil || got != want {
		t.Errorf("got %q, %v", got, err)
	}
}

// A directory named foo.profile is not a profile: without the IsDir check, Stat would succeed and
// the caller would get a "is a directory" read error from Parse instead of a clear resolve error.
func TestResolveIgnoresADirectoryNamedLikeAProfile(t *testing.T) {
	d := t.TempDir()
	if err := os.MkdirAll(filepath.Join(d, "trap.profile"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve("trap", []string{d}, "/cwd"); err == nil {
		t.Error("a directory must not resolve as a profile")
	}
}

// Resolve then Parse is the real call sequence; running it against a shipped name proves the two
// halves fit together and that the shipped profile directory is a valid dirs entry.
func TestResolveThenParseOnAShippedName(t *testing.T) {
	p, err := Resolve("production-enterprise", []string{"../../profiles"}, ".")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Parse(p); err != nil {
		t.Fatalf("Parse(%s): %v", p, err)
	}
}
