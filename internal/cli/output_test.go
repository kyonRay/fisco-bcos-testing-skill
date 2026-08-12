package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

// In machine modes the host's stdout is the product, so the failure document goes there; a
// consumer that only reads stdout must never see an empty document and a nonzero code with no
// explanation. Human mode keeps the convention of diagnostics on stderr.
func TestErrorGoesToStdoutInMachineModesAndStderrInHuman(t *testing.T) {
	for _, mode := range []OutputMode{OutputJSON, OutputJSONL} {
		var out, errOut bytes.Buffer
		emitError(&out, &errOut, mode, fbterr.Configf("bad thing"))
		if out.Len() == 0 {
			t.Errorf("%v: nothing on stdout", mode)
		}
		if errOut.Len() != 0 {
			t.Errorf("%v: stderr must stay clean, got %q", mode, errOut.String())
		}
	}
	var out, errOut bytes.Buffer
	emitError(&out, &errOut, OutputHuman, fbterr.Configf("bad thing"))
	if out.Len() != 0 || !strings.Contains(errOut.String(), "bad thing") {
		t.Errorf("human: stdout=%q stderr=%q", out.String(), errOut.String())
	}
}

func TestErrorDocumentCarriesClassAndExitCode(t *testing.T) {
	var out, errOut bytes.Buffer
	code := emitError(&out, &errOut, OutputJSON, fbterr.Infraf("cluster unreachable"))
	if code != exitcode.Infra {
		t.Errorf("code = %v, want 30", code)
	}
	var doc struct {
		OK    bool `json:"ok"`
		Error struct {
			Message string `json:"message"`
			Class   string `json:"class"`
		} `json:"error"`
		ExitCode int `json:"exit_code"`
	}
	if err := json.Unmarshal(out.Bytes(), &doc); err != nil {
		t.Fatalf("not JSON: %v (%q)", err, out.String())
	}
	if doc.OK || doc.ExitCode != 30 || doc.Error.Class != "infra" ||
		!strings.Contains(doc.Error.Message, "cluster unreachable") {
		t.Errorf("doc = %+v", doc)
	}
}

// An unclassified error is fbt's own bug, not the user's misconfiguration: 40, not 20.
func TestUnclassifiedErrorIsHostClass(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := emitError(&out, &errOut, OutputHuman, errPlain("boom")); code != exitcode.Host {
		t.Errorf("code = %v, want 40", code)
	}
}

type errPlain string

func (e errPlain) Error() string { return string(e) }

// jsonl is a stream: every document must be exactly one line, or a reader splitting on newlines
// gets fragments.
func TestJSONLDocumentsAreSingleLines(t *testing.T) {
	var out, errOut bytes.Buffer
	emitError(&out, &errOut, OutputJSONL, fbterr.Configf("multi\nline\nmessage"))
	s := strings.TrimSuffix(out.String(), "\n")
	if strings.Contains(s, "\n") {
		t.Errorf("jsonl error spans several lines: %q", out.String())
	}
	if !json.Valid([]byte(s)) {
		t.Errorf("jsonl error is not valid JSON: %q", s)
	}
}

func TestRenderEmitsTheSameDocumentInBothMachineModes(t *testing.T) {
	doc := map[string]interface{}{"a": 1, "b": "two"}
	var pretty, compact bytes.Buffer
	if err := render(&pretty, OutputJSON, doc, nil); err != nil {
		t.Fatal(err)
	}
	if err := render(&compact, OutputJSONL, doc, nil); err != nil {
		t.Fatal(err)
	}
	var a, b map[string]interface{}
	if err := json.Unmarshal(pretty.Bytes(), &a); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(compact.Bytes(), &b); err != nil {
		t.Fatal(err)
	}
	if len(a) != len(b) || a["b"] != b["b"] {
		t.Errorf("json %+v and jsonl %+v differ", a, b)
	}
	if strings.Count(strings.TrimSuffix(compact.String(), "\n"), "\n") != 0 {
		t.Errorf("jsonl document is not one line: %q", compact.String())
	}
}

// A static command has no event stream. Falling back to the human table under --output jsonl would
// hand the caller unparseable text with exit code 0 -- the worst possible combination.
func TestJSONLNeverFallsBackToHumanText(t *testing.T) {
	var out bytes.Buffer
	err := render(&out, OutputJSONL, map[string]string{"k": "v"}, func(w io.Writer) {
		w.Write([]byte("a pretty table\n"))
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "pretty table") {
		t.Errorf("jsonl fell back to the human renderer: %q", out.String())
	}
}

func TestHumanRenderUsesTheHumanFunc(t *testing.T) {
	var out bytes.Buffer
	if err := render(&out, OutputHuman, map[string]string{"k": "v"}, func(w io.Writer) {
		w.Write([]byte("a pretty table\n"))
	}); err != nil {
		t.Fatal(err)
	}
	if out.String() != "a pretty table\n" {
		t.Errorf("got %q", out.String())
	}
}

// A document that cannot be marshalled is a programming error inside fbt; it must surface as 40
// rather than as a truncated stdout with exit 0.
func TestUnmarshallableDocumentIsAHostError(t *testing.T) {
	var out bytes.Buffer
	err := render(&out, OutputJSON, make(chan int), nil)
	if err == nil {
		t.Fatal("want an error")
	}
	if c, ok := fbterr.ClassOf(err); !ok || c != fbterr.ClassHost {
		t.Errorf("want ClassHost, got %v", c)
	}
}
