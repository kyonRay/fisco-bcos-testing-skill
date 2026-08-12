// Package cases parses .case regression fixtures and enumerates the two directories they live in.
//
// A .case pins down the CORRECT post-fix behaviour of one input against one profile. Its status
// decides whether the gate sweeps it, which is why status is mandatory rather than defaulted: an
// earlier design treated a missing status as "example", and the effect of that on an existing
// fixture set is that real regression cases silently stop running after an upgrade while the gate
// keeps reporting green (spec §6.4).
package cases

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

type Status string

const (
	// StatusActive: a confirmed fix. Swept by the gate; a failure fails the gate.
	StatusActive Status = "active"
	// StatusPending: found, not yet fixed. Reported by `case list`, never swept -- replaying it is
	// expected to fail until the fix lands, so sweeping it would make the gate permanently red.
	StatusPending Status = "pending"
	// StatusExample: a format demonstration. Never swept.
	StatusExample Status = "example"
)

// Expect is what the input is supposed to do.
type Expect string

const (
	ExpectPass   Expect = "pass"   // a valid operation: it must apply cleanly and trip no oracle
	ExpectReject Expect = "reject" // malformed input: it must be refused AND the node must survive
)

// Case is one fixture.
type Case struct {
	Path    string `json:"path"`
	Name    string `json:"name"` // the basename, which is how a case is named on the command line
	Status  Status `json:"status"`
	Profile string `json:"profile"`
	Input   string `json:"input"`
	Expect  Expect `json:"expect_oracle"`
	// Source records which registry the file came from, so `case list` can show why two files with
	// the same name conflict.
	Source string `json:"source"` // "shipped" or "state"
}

// Sweepable reports whether the gate runs this case. Only active fixtures are swept: pending ones
// are reported by `case list` and example ones never run at all.
func (c Case) Sweepable() bool { return c.Status == StatusActive }

var knownKeys = map[string]bool{
	"status": true, "profile": true, "input": true, "expect_oracle": true,
}

// Parse reads one .case file.
//
// Every failure here is a configuration error (exit 20) and every one of them names the file and
// the field. These are hand-written files, and the parse runs before any chain is started (spec
// §6.4), so a typo costs a message rather than a stranded cluster.
func Parse(path string) (Case, error) {
	f, err := os.Open(path)
	if err != nil {
		return Case{}, fbterr.Infraf("cannot read case %s: %v", path, err)
	}
	defer f.Close()

	c := Case{Path: path, Name: filepath.Base(path)}
	seen := map[string]int{}
	section := ""
	sc := bufio.NewScanner(f)
	line := 0
	for sc.Scan() {
		line++
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		if strings.HasPrefix(text, "[") {
			if !strings.HasSuffix(text, "]") {
				return c, fbterr.Configf("%s:%d: unterminated section header %q", path, line, text)
			}
			section = strings.TrimSpace(text[1 : len(text)-1])
			if section != "case" {
				return c, fbterr.Configf("%s:%d: unknown section [%s]; a .case file has exactly "+
					"one [case] section", path, line, section)
			}
			continue
		}
		if section != "case" {
			return c, fbterr.Configf("%s:%d: %q appears before the [case] section", path, line, text)
		}
		eq := strings.IndexByte(text, '=')
		if eq < 0 {
			return c, fbterr.Configf("%s:%d: %q is not a key = value line", path, line, text)
		}
		key := strings.TrimSpace(text[:eq])
		// The value keeps everything after the first '=' -- an input is a shell command and
		// routinely contains '=', quotes and JSON.
		value := strings.TrimSpace(text[eq+1:])
		if !knownKeys[key] {
			// run_case.sh silently ignores unknown keys, the way profile_lib.sh does. fbt does
			// not, deliberately: a mistyped `expect_orcale` there produces "expect_oracle is
			// missing" and sends the author looking for a line that is right in front of them.
			return c, fbterr.Configf("%s:%d: unknown key %q%s", path, line, key, didYouMean(key))
		}
		if prev, dup := seen[key]; dup {
			return c, fbterr.Configf("%s:%d: %s is set twice (first at line %d); which one wins "+
				"would decide what this fixture actually tests", path, line, key, prev)
		}
		seen[key] = line
		switch key {
		case "status":
			c.Status = Status(value)
		case "profile":
			c.Profile = value
		case "input":
			c.Input = value
		case "expect_oracle":
			c.Expect = Expect(value)
		}
	}
	if err := sc.Err(); err != nil {
		return c, fbterr.Infraf("cannot read case %s: %v", path, err)
	}
	return c, c.validate()
}

func (c Case) validate() error {
	switch c.Status {
	case StatusActive, StatusPending, StatusExample:
	case "":
		return fbterr.Configf("%s: status is required and must be active, pending or example; "+
			"without it fbt cannot tell a live regression fixture from a format example, and "+
			"guessing would let real cases stop running silently", c.Path)
	default:
		return fbterr.Configf("%s: status = %q is not one of active, pending, example",
			c.Path, c.Status)
	}
	if c.Profile == "" {
		return fbterr.Configf("%s: profile is required", c.Path)
	}
	if c.Input == "" {
		return fbterr.Configf("%s: input is required", c.Path)
	}
	switch c.Expect {
	case ExpectPass, ExpectReject:
	case "":
		return fbterr.Configf("%s: expect_oracle is required and must be pass or reject", c.Path)
	default:
		return fbterr.Configf("%s: expect_oracle = %q is not pass or reject", c.Path, c.Expect)
	}
	return nil
}

// didYouMean points at the intended key when an unknown one is one edit away from a real one.
func didYouMean(key string) string {
	best, bestDist := "", 3
	for known := range knownKeys {
		if d := editDistance(key, known); d < bestDist {
			best, bestDist = known, d
		}
	}
	if best == "" {
		return "; a [case] takes status, profile, input and expect_oracle"
	}
	return fmt.Sprintf("; did you mean %q?", best)
}

func editDistance(a, b string) int {
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		cur[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min3(cur[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

func min3(a, b, c int) int {
	if b < a {
		a = b
	}
	if c < a {
		a = c
	}
	return a
}

// Registry enumerates the two case directories: the read-only one that ships with the engine, and
// the writable one under the state directory that fuzz runs and users add to (spec §5).
type Registry struct {
	Shipped string
	State   string
}

// List returns every case from both directories, by basename, with every file parsed.
//
// Two files with the same basename are a CONFLICT, not a shadowing (spec §5). Letting one win
// silently means a user editing the shipped copy sees no effect, or -- worse -- a stale state copy
// quietly replaces a fixture the release shipped, and the gate then tests something other than
// what it reports.
//
// Every file is parsed here, before anything starts a chain, so one malformed fixture is a message
// rather than a failure discovered with a cluster already up.
func (r Registry) List() ([]Case, error) {
	byName := map[string]Case{}
	var out []Case
	for _, src := range []struct{ dir, label string }{
		{r.Shipped, "shipped"}, {r.State, "state"},
	} {
		if src.dir == "" {
			continue
		}
		paths, err := filepath.Glob(filepath.Join(src.dir, "*.case"))
		if err != nil {
			return nil, fbterr.Infraf("cannot list cases in %s: %v", src.dir, err)
		}
		sort.Strings(paths)
		for _, p := range paths {
			c, err := Parse(p)
			if err != nil {
				return nil, err
			}
			c.Source = src.label
			if prev, dup := byName[c.Name]; dup {
				return nil, fbterr.Configf("two cases are both named %s (%s and %s); rename one "+
					"-- fbt will not pick a winner, because the loser would silently stop being "+
					"tested", c.Name, prev.Path, c.Path)
			}
			byName[c.Name] = c
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Sweep returns the cases a gate round runs: the active ones, in name order.
func Sweep(all []Case) []Case {
	out := make([]Case, 0, len(all))
	for _, c := range all {
		if c.Sweepable() {
			out = append(out, c)
		}
	}
	return out
}

// Find resolves a case named on the command line: a basename, with or without the .case suffix, or
// a path to a file.
func (r Registry) Find(name string) (Case, error) {
	if strings.ContainsRune(name, filepath.Separator) {
		return Parse(name)
	}
	all, err := r.List()
	if err != nil {
		return Case{}, err
	}
	want := name
	if !strings.HasSuffix(want, ".case") {
		want += ".case"
	}
	for _, c := range all {
		if c.Name == want {
			return c, nil
		}
	}
	names := make([]string, 0, len(all))
	for _, c := range all {
		names = append(names, c.Name)
	}
	if len(names) == 0 {
		return Case{}, fbterr.Configf("no case named %s, and no cases are installed", name)
	}
	return Case{}, fbterr.Configf("no case named %s; available: %s", name, strings.Join(names, ", "))
}
