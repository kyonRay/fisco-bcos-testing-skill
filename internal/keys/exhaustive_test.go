package keys

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// scanDirs covers ALL THREE trees the engine spans. Missing any of them makes the check pass
// vacuously for that tree: tools/ alone holds TAMPER_BLOCK_LIMIT, and the sibling checkout holds
// cluster_up.sh / run_ut.sh.
var scanDirs = []string{
	"../../scripts",
	"../../tools",
	"../../../fisco-bcos-testing/scripts",
}

var readPattern = regexp.MustCompile(`\$\{([A-Z_][A-Z0-9_]*):-`)

// engineInternal exempts names that DO appear in the ${VAR:-} scan but are not user-configurable:
// each is a script's own flag default or a value the script computes before validating it.
//
// Variables the scripts merely ASSIGN (JSD_RUNS, MAL_CASES, CLUSTER_OUTDIR, FAILURES_*, FILE_ID,
// SHEET_ID, FISCO_BIN_FOR_T0, APPLY_PROFILE) are deliberately NOT listed: they never match the
// ${VAR:-} read pattern, so they can never turn up as unaccounted, and listing them would be dead
// weight that quietly widens the exemption if one of them later became env-readable.
var engineInternal = map[string]string{
	"RPC_URL":        "oracle_liveness.sh:32 - that script's own -r flag default",
	"POLL_INTERVAL":  "oracle_liveness.sh:33 - its own polling knob; the host passes flags instead",
	"SAMPLES":        "oracle_liveness.sh:34 - its own sampling knob",
	"BIN":            "run_ut.sh:43 - computed inside the script, then validated",
	"COMPAT_VERSION": "cluster_up.sh - assigned from getopts -v; argv-driven, not env",
}

// hostOwnedEnv is fbt's own environment, not an engine passthrough. Separate from engineInternal
// because these need no justification against the engine and may legitimately be absent.
var hostOwnedEnv = map[string]bool{"HOME": true, "XDG_STATE_HOME": true, "PATH": true}

func scanScripts(t *testing.T) (files int, vars map[string]bool) {
	t.Helper()
	vars = map[string]bool{}
	for _, d := range scanDirs {
		err := filepath.Walk(d, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(p, ".sh") {
				return nil
			}
			files++
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			for _, m := range readPattern.FindAllSubmatch(b, -1) {
				vars[string(m[1])] = true
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", d, err)
		}
	}
	return files, vars
}

// The long-term guard: notice when the engine grows a variable the host never learns to set.
func TestTableCoversEveryExternallyReadEngineVar(t *testing.T) {
	files, vars := scanScripts(t)

	// Without these two floors a wrong path makes the assertion below vacuous and the test would
	// pass while checking nothing.
	if files < 15 {
		t.Fatalf("scanned only %d .sh files across %v -- a path is wrong and this test would "+
			"pass vacuously", files, scanDirs)
	}
	if len(vars) < 40 {
		t.Fatalf("found only %d environment-read variables; expected at least 40", len(vars))
	}

	bound := map[string]bool{}
	for _, r := range Rows() {
		for _, e := range r.Env {
			bound[e] = true
		}
	}
	var unaccounted []string
	for v := range vars {
		if bound[v] || IsStripped(v) {
			continue
		}
		if _, ok := engineInternal[v]; ok {
			continue
		}
		if hostOwnedEnv[v] {
			continue
		}
		unaccounted = append(unaccounted, v)
	}
	sort.Strings(unaccounted)
	for _, v := range unaccounted {
		t.Errorf("engine reads %s from the environment but nothing binds it: add a table row, "+
			"add it to the strip list if it substitutes a script, or add it to engineInternal "+
			"with a reason", v)
	}
}

// The strip list must stay real: a name nothing reads any more gives false confidence.
func TestEveryStrippedNameStillAppearsInTheScripts(t *testing.T) {
	_, vars := scanScripts(t)
	for _, s := range MustStrip() {
		if !vars[s] {
			t.Errorf("%s is on the strip list but no script reads it any more -- remove it or "+
				"fix the name", s)
		}
	}
}

// Same for engineInternal: a stale entry silently widens the exemption.
func TestEveryEngineInternalNameStillAppears(t *testing.T) {
	_, vars := scanScripts(t)
	for name := range engineInternal {
		if !vars[name] {
			t.Errorf("%s is exempted as engine-internal but no script reads it any more", name)
		}
	}
}
