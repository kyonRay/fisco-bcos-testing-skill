// Package testinstall builds a throwaway fbt install tree for tests.
//
// It lives in its own package, not in paths/, so the `testing` import never reaches the published
// binary. Tests must build one of these rather than assume the source checkout looks like an
// install: the repository keeps scripts/ and profiles/ at its root, while an install puts them
// under libexec/fbt/ and share/fbt/ -- different shapes entirely.
package testinstall

import (
	"os"
	"path/filepath"
	"testing"
)

type Install struct {
	Root  string // pass to --engine-dir
	State string // pass to --state-dir
}

const engineJSON = `{
  "engine_protocol_version": "1.0.0",
  "event_schema_version": "1.0.0",
  "output_schema_version": "1.0.0",
  "capabilities": ["gate", "cluster", "case", "fuzz", "upgrade", "ut"]
}`

// Profile is a minimal but VALID profile: [genesis] compatibility_version is mandatory, and the
// replay order below is the dependency chain the chain itself enforces.
const Profile = `[meta]
source_chain = fixture
captured_at = 2026-08-11
[genesis]
compatibility_version = 3.16.4
[system_config_replay]
feature_balance = 1
feature_balance_precompiled = 1
auth_check_status = 1
[config_ini_override]
web3_rpc.listen_port = 8545
`

func New(t *testing.T) Install {
	t.Helper()
	root := t.TempDir()
	state := filepath.Join(root, "state")
	for _, d := range [][]string{
		{"libexec", "fbt", "scripts"},
		{"share", "fbt", "profiles"},
		{"share", "fbt", "cases"},
	} {
		if err := os.MkdirAll(filepath.Join(append([]string{root}, d...)...), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	if err := os.MkdirAll(state, 0o755); err != nil {
		t.Fatalf("mkdir state: %v", err)
	}
	write(t, filepath.Join(root, "libexec", "fbt", "engine.json"), engineJSON)
	for _, n := range []string{"default-latest", "production-enterprise"} {
		write(t, filepath.Join(root, "share", "fbt", "profiles", n+".profile"), Profile)
	}
	return Install{Root: root, State: state}
}

// WriteProfile adds another .profile, for tests that need a specific shape.
func (i Install) WriteProfile(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(i.Root, "share", "fbt", "profiles", name+".profile")
	write(t, p, body)
	return p
}

// Scripts is the directory an installed engine keeps its executables in.
func (i Install) Scripts() string { return filepath.Join(i.Root, "libexec", "fbt", "scripts") }

// WriteScript installs a stand-in engine script. It lands at 0755 on purpose: the host EXECS these
// files, and a 0644 script fails with a bare permission-denied -- which is exactly what shipped
// once, because every bash test invokes scripts as `bash x.sh` and never noticed.
func (i Install) WriteScript(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(i.Scripts(), name)
	if err := os.WriteFile(p, []byte("#!/usr/bin/env bash\n"+body), 0o755); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

// WriteConfig drops an fbt.yaml into the install root and returns its path.
func (i Install) WriteConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(i.Root, "fbt.yaml")
	write(t, p, body)
	return p
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
