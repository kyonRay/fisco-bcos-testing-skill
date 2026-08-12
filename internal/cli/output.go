package cli

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// OutputMode is the shape of everything fbt writes to stdout (spec §8).
type OutputMode int

const (
	OutputHuman OutputMode = iota
	OutputJSON
	OutputJSONL
)

func (m OutputMode) String() string {
	switch m {
	case OutputHuman:
		return "human"
	case OutputJSON:
		return "json"
	case OutputJSONL:
		return "jsonl"
	}
	return "unknown"
}

func ParseOutputMode(s string) (OutputMode, error) {
	switch s {
	case "human":
		return OutputHuman, nil
	case "json":
		return OutputJSON, nil
	case "jsonl":
		return OutputJSONL, nil
	}
	return OutputHuman, fbterr.Configf("--output must be human, json or jsonl, got %q", s)
}

// errorDoc is spec §11's top-level failure object, field for field:
//
//	{"exit":30,"class":"infra","reason":"...","evidence_path":"..."}
//
// The shape is the spec's, not a convenience of this package: the spec tells UI and CI authors to
// build against it, and a second spelling here would mean everything downstream has to handle two.
// EvidencePath is omitted until there is one -- run-time failures gain it when the workspace lands.
type errorDoc struct {
	Exit         int    `json:"exit"`
	Class        string `json:"class"`
	Reason       string `json:"reason"`
	EvidencePath string `json:"evidence_path,omitempty"`
}

// emitError writes a failure in the requested shape and returns the code to exit with. EVERY
// failure path goes through here -- global flag parse failure, unknown command, unknown
// subcommand, a subcommand's own flag parse failure, a missing required argument, --ai on, and a
// --config naming a file that does not exist. A path that prints prose to stderr instead forces
// consumers back to parsing human text, which is exactly what --output json exists to eliminate.
//
// In machine modes the document goes to STDOUT, because in those modes stdout is the product: a
// consumer reading only stdout must not get an empty stream and a nonzero code with no
// explanation. Human mode keeps diagnostics on stderr.
func emitError(stdout, stderr io.Writer, mode OutputMode, err error) exitcode.Code {
	code := exitcode.FromError(err)
	class, ok := fbterr.ClassOf(err)
	if !ok {
		// Unclassified means fbt never labelled this path: that is fbt's own bug (40), not the
		// user's misconfiguration (20).
		class = fbterr.ClassHost
	}
	doc := errorDoc{Exit: code.Int(), Class: class.String(), Reason: err.Error()}

	switch mode {
	case OutputJSON, OutputJSONL:
		// Ignore the write error: there is nowhere left to report it, and the exit code still
		// carries the failure.
		_ = render(stdout, mode, doc, nil)
	default:
		fmt.Fprintf(stderr, "fbt: %v\n", err)
	}
	return code
}

// render writes a success document in the requested shape. jsonl emits the SAME document as json,
// compacted onto one line: a static command has no event stream, and silently degrading to a human
// table would hand a --output jsonl caller unparseable text with exit code 0.
func render(stdout io.Writer, mode OutputMode, doc interface{}, human func(io.Writer)) error {
	switch mode {
	case OutputJSON, OutputJSONL:
		enc := json.NewEncoder(stdout)
		// HTML escaping exists for JSON embedded in a web page. Here it only rewrites the angle
		// brackets of "<redacted>" and the ampersands in URLs into \u escapes, making the output
		// harder to read and to grep for no benefit.
		enc.SetEscapeHTML(false)
		if mode == OutputJSON {
			enc.SetIndent("", "  ")
		}
		// Encode writes exactly one trailing newline, so a jsonl document is one line.
		if err := enc.Encode(doc); err != nil {
			return fbterr.Hostf("cannot encode the output document: %v", err)
		}
		return nil
	default:
		if human != nil {
			human(stdout)
		}
		return nil
	}
}
