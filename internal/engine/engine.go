// Package engine reads the engine's manifest and decides whether this host can drive it. The
// check runs BEFORE any chain is touched (spec §5): discovering a protocol mismatch halfway
// through a gate run would strand a live cluster.
package engine

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// The majors this host speaks. Bump one only alongside a breaking change to that contract.
const (
	SupportedProtocolMajor = 1
	SupportedEventMajor    = 1
)

type Manifest struct {
	EngineProtocolVersion string   `json:"engine_protocol_version"`
	EventSchemaVersion    string   `json:"event_schema_version"`
	OutputSchemaVersion   string   `json:"output_schema_version"`
	Capabilities          []string `json:"capabilities"`
}

func Load(path string) (Manifest, error) {
	var m Manifest
	b, err := os.ReadFile(path)
	if err != nil {
		return m, fbterr.Infraf("cannot read engine manifest %s: %v (is the installation "+
			"complete? pass --engine-dir to point at the install root)", path, err)
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return m, fbterr.Hostf("engine manifest %s is not valid JSON: %v", path, err)
	}
	return m, nil
}

func (m Manifest) Has(capability string) bool {
	for _, c := range m.Capabilities {
		if c == capability {
			return true
		}
	}
	return false
}

// EventMajor is the major of event_schema_version, which the event normalizer uses to validate
// every individual event (spec §8). Only meaningful after Check has passed.
func (m Manifest) EventMajor() (int, error) {
	major, _, _, err := ParseSemver(m.EventSchemaVersion)
	return major, err
}

// Check validates all three declared versions. Two of them gate execution:
//
//   - engine_protocol_version: the argv and exit conventions this host drives the scripts with.
//   - event_schema_version: how the fd-3 stream is framed. A different major means the host would
//     misread every event.
//
// output_schema_version describes the JSON fbt prints for OTHER tools; a mismatch there cannot
// corrupt this run's judgment, so it is validated for well-formedness and otherwise recorded.
// All three must be PRESENT and well-formed: a manifest missing one states no contract at all.
func (m Manifest) Check() error {
	for _, g := range []struct {
		field, value string
		want         int
		blocking     bool
	}{
		{"engine_protocol_version", m.EngineProtocolVersion, SupportedProtocolMajor, true},
		{"event_schema_version", m.EventSchemaVersion, SupportedEventMajor, true},
		{"output_schema_version", m.OutputSchemaVersion, 0, false},
	} {
		if strings.TrimSpace(g.value) == "" {
			return fbterr.Hostf("engine manifest does not declare %s", g.field)
		}
		major, _, _, err := ParseSemver(g.value)
		if err != nil {
			return fbterr.Hostf("engine manifest %s = %q is not a semver string: %v",
				g.field, g.value, err)
		}
		if g.blocking && major != g.want {
			return fbterr.Hostf("engine %s major is %d but this fbt build speaks %d; upgrade fbt "+
				"or point --engine-dir at a matching engine", g.field, major, g.want)
		}
	}
	return nil
}

// ParseSemver accepts exactly MAJOR.MINOR.PATCH of non-negative integers. Deliberately strict:
// accepting "1" or "v1.0.0" would let a typo in the manifest read as a compatible version.
func ParseSemver(s string) (major, minor, patch int, err error) {
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return 0, 0, 0, fbterr.Hostf("expected MAJOR.MINOR.PATCH, got %q", s)
	}
	out := make([]int, 3)
	for i, p := range parts {
		if p == "" {
			return 0, 0, 0, fbterr.Hostf("empty component in %q", s)
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return 0, 0, 0, fbterr.Hostf("non-numeric component %q in %q", p, s)
			}
		}
		n, convErr := strconv.Atoi(p)
		if convErr != nil {
			return 0, 0, 0, fbterr.Hostf("component %q in %q: %v", p, s, convErr)
		}
		out[i] = n
	}
	return out[0], out[1], out[2], nil
}
