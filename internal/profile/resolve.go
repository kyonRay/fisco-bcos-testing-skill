package profile

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// Resolve turns a -p argument into an absolute profile path (spec §7.2). A spec containing a path
// separator or ending in .profile is a PATH, resolved against baseDir; anything else is a logical
// NAME looked up in dirs. The same name in two directories is refused rather than silently picked,
// because which one won would decide what chain the run reproduces -- and the report only ever
// records the name the user typed.
func Resolve(spec string, dirs []string, baseDir string) (string, error) {
	if spec == "" {
		return "", fbterr.Configf("no profile given: pass -p <name|path>")
	}
	if strings.ContainsRune(spec, filepath.Separator) || strings.HasSuffix(spec, ".profile") {
		p := spec
		if !filepath.IsAbs(p) {
			p = filepath.Join(baseDir, p)
		}
		if st, err := os.Stat(p); err != nil || st.IsDir() {
			return "", fbterr.Configf("profile file not found: %s", p)
		}
		return p, nil
	}
	var hits []string
	for _, d := range dirs {
		if d == "" {
			continue
		}
		cand := filepath.Join(d, spec+".profile")
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			hits = append(hits, cand)
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return "", fbterr.Configf("no profile named %q in %v (use -p <path> for a file outside "+
			"the profile directories)", spec, dirs)
	default:
		return "", fbterr.Configf("profile name %q is ambiguous, found in %d places: %v -- pass "+
			"an explicit path instead", spec, len(hits), hits)
	}
}
