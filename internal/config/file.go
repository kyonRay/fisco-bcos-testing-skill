// Package config turns the user's declared configuration into validated, engine-ready values.
// This file covers the YAML layer only; the five-layer merge lives in merge.go.
package config

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"gopkg.in/yaml.v3"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/keys"
)

// LoadFile reads fbt.yaml and flattens it to validated, dotted, string-valued keys.
//
// explicit says the path came from --config. A named file that is absent is an infrastructure
// error, because the user's settings would otherwise disappear silently and the run would proceed
// under defaults nobody asked for; an absent file at a default location is ordinary.
func LoadFile(path string, explicit bool) (map[string]string, error) {
	if path == "" {
		return map[string]string{}, nil
	}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		if explicit {
			return nil, fbterr.Infraf("config file %s does not exist (it was named explicitly "+
				"with --config)", path)
		}
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, fbterr.Infraf("cannot read %s: %v", path, err)
	}
	var root map[string]interface{}
	if err := yaml.Unmarshal(b, &root); err != nil {
		return nil, fbterr.Configf("%s is not valid YAML: %v", path, err)
	}
	flat := map[string]string{}
	if err := flatten("", root, flat); err != nil {
		return nil, fbterr.Configf("%s: %v", path, err)
	}

	baseDir := filepath.Dir(path)
	out := make(map[string]string, len(flat))
	// Sorted, so a file with several bad keys always reports the same one first: an error message
	// that changes between identical runs is unreproducible.
	for _, k := range sortedKeys(flat) {
		if !keys.IsKnown(k) {
			return nil, fbterr.Configf("%s: unknown key %q%s", path, k, suggest(k))
		}
		if err := keys.Validate(k, flat[k]); err != nil {
			return nil, fbterr.Configf("%s: %v", path, err)
		}
		v := flat[k]
		if r, _ := keys.Lookup(k); r.Type == keys.KindPath && v != "" && !filepath.IsAbs(v) {
			v = filepath.Join(baseDir, v) // spec §7.3
		}
		out[k] = v
	}
	return out, nil
}

// flatten walks the document into dotted keys. Every leaf must be a scalar, and every scalar is
// stringified here -- downstream (env injection, `config show`, the engine itself) is
// string-valued, so keeping YAML's types alive past this point would only invite two spellings of
// the same value.
func flatten(prefix string, node interface{}, out map[string]string) error {
	switch v := node.(type) {
	case nil:
		// A null leaf is a value the user erased; a null root is simply an empty document.
		if prefix != "" {
			return fbterr.Configf("key %q has no value (write a value or delete the line)", prefix)
		}
	case map[string]interface{}:
		for k, child := range v {
			p := k
			if prefix != "" {
				p = prefix + "." + k
			}
			if err := flatten(p, child, out); err != nil {
				return err
			}
		}
	case string:
		out[prefix] = v
	case bool:
		out[prefix] = strconv.FormatBool(v)
	case int:
		out[prefix] = strconv.Itoa(v)
	case int64:
		out[prefix] = strconv.FormatInt(v, 10)
	case uint64: // yaml.v3 falls back to uint64 for positive values that overflow int64
		out[prefix] = strconv.FormatUint(v, 10)
	case float64:
		out[prefix] = strconv.FormatFloat(v, 'f', -1, 64)
	default:
		return fbterr.Configf("key %q must be a scalar (string, number or boolean), got %T",
			prefix, node)
	}
	return nil
}

// suggest offers the nearest known key, so a typo does not force the user to diff the key list.
func suggest(k string) string {
	for _, r := range keys.Rows() {
		if levenshtein(k, r.Key) <= 2 {
			return " (did you mean \"" + r.Key + "\"?)"
		}
	}
	return ""
}

func levenshtein(a, b string) int {
	prev, cur := make([]int, len(b)+1), make([]int, len(b)+1)
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
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}

func sortedKeys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
