// Package profile parses a .profile -- the captured configuration of one chain. The section
// vocabulary, the split-on-first-'=' rule and the duplicate-key semantics mirror
// scripts/profile_lib.sh's profile_load, which is the authority on the format: the host and the
// engine must agree byte-for-byte on what a profile says, or a run reproduces a different chain
// than the one it reports.
//
// Two deliberate departures from the bash, both in the direction of refusing what bash silently
// drops (its `case "$section"` has no default arm): an unknown [section] and a key above the first
// header are errors here. Losing half a replay list to a typo and still exiting 0 is the exact
// false-green this tooling exists to prevent.
package profile

import (
	"bufio"
	"os"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// KV is one `key = value` line, kept as a slice element rather than a map entry because the order
// of [system_config_replay] is load-bearing -- see orderedSet.
type KV struct{ Key, Value string }

type Profile struct {
	Path      string
	Meta      map[string]string
	Genesis   map[string]string
	Replay    []KV
	ConfigINI []KV
}

// orderedSet reproduces profile_lib.sh's two-array idiom (PROFILE_REPLAY + PROFILE_REPLAY_ORDER,
// lines 75 and 79): the first occurrence of a key fixes its position, later assignments overwrite
// the value in place, and the key is emitted exactly once. Plain appending would replay
// auth_check_status twice, and the second call comes back "Permission denied" because the first
// one switched committee governance on.
type orderedSet struct {
	at   map[string]int
	vals []KV
}

func newOrderedSet() *orderedSet { return &orderedSet{at: map[string]int{}} }

func (o *orderedSet) put(k, v string) {
	if i, seen := o.at[k]; seen {
		o.vals[i].Value = v // last assignment wins, position unchanged
		return
	}
	o.at[k] = len(o.vals)
	o.vals = append(o.vals, KV{k, v})
}

func Parse(path string) (Profile, error) {
	f, err := os.Open(path)
	if err != nil {
		return Profile{}, fbterr.Infraf("cannot read profile %s: %v", path, err)
	}
	defer f.Close()

	p := Profile{Path: path, Meta: map[string]string{}, Genesis: map[string]string{}}
	replay, cfg := newOrderedSet(), newOrderedSet()
	section := ""
	sc := bufio.NewScanner(f)
	for line := 1; sc.Scan(); line++ {
		s := strings.TrimSpace(sc.Text())
		// Only '#', matching profile_lib.sh:54. A ';'-led line still holds a '=' and bash records
		// it as a key, so skipping it here would make the two disagree about the file's contents.
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		if strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]") {
			section = s[1 : len(s)-1]
			switch section {
			case "meta", "genesis", "system_config_replay", "config_ini_override":
			default:
				return Profile{}, fbterr.Configf("%s:%d: unknown section [%s] (expected "+
					"meta/genesis/system_config_replay/config_ini_override)", path, line, section)
			}
			continue
		}
		i := strings.IndexByte(s, '=')
		if i < 0 {
			return Profile{}, fbterr.Configf("%s:%d: expected `key = value`, got %q", path, line, s)
		}
		// Split on the FIRST '=' only (profile_lib.sh:63-64): values legitimately contain more of
		// them, e.g. a cert subject or a URL query.
		k, v := strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+1:])
		switch section {
		case "meta":
			p.Meta[k] = v
		case "genesis":
			p.Genesis[k] = v
		case "system_config_replay":
			replay.put(k, v)
		case "config_ini_override":
			cfg.put(k, v)
		default: // section == "": nothing but an unknown-section error can reach here otherwise
			return Profile{}, fbterr.Configf("%s:%d: key %q appears before any [section] header",
				path, line, k)
		}
	}
	if err := sc.Err(); err != nil {
		return Profile{}, fbterr.Infraf("reading %s: %v", path, err)
	}
	if strings.TrimSpace(p.Genesis["compatibility_version"]) == "" {
		return Profile{}, fbterr.Configf("%s: [genesis] compatibility_version is required "+
			"(it drives build_chain -v and the whole upgrade path)", path)
	}
	p.Replay, p.ConfigINI = replay.vals, cfg.vals
	return p, nil
}
