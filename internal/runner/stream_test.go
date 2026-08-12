package runner

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// A gate round takes minutes and the engine narrates it the whole way. Holding that narration until
// the process exits means an operator watching a 20-minute run sees nothing until it is over, and a
// run the host later kills on deadline shows nothing at all -- exactly when the output matters most.
func TestOutputReachesTheWriterWhileTheEngineIsStillRunning(t *testing.T) {
	var mu sync.Mutex
	seen := make(chan string, 4)
	w := writerFunc(func(p []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		select {
		case seen <- string(p):
		default:
		}
		return len(p), nil
	})

	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = Run(context.Background(), Spec{
			// Announces itself, then stays alive well past the assertion below.
			Script: script(t, "echo alive; sleep 10\n"),
			Dir:    t.TempDir(),
			Stdout: w,
			// The deadline is the backstop: if forwarding is broken the test still ends.
			Timeout: 6 * time.Second,
		})
	}()

	select {
	case line := <-seen:
		if !strings.Contains(line, "alive") {
			t.Errorf("first forwarded chunk = %q, want the engine's own line", line)
		}
	case <-time.After(startupSlack + 2*time.Second):
		t.Fatal("nothing was forwarded while the engine was still running: " +
			"the output is being buffered until exit")
	}
	<-done
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

// A chatty engine -- a fuzz batch, a node dumping its log to stdout -- must not be able to grow the
// host's memory without bound. Result keeps a TAIL, because the tail is what a diagnostic needs
// (spec §11: "原样透出 stderr 尾部").
func TestResultKeepsABoundedTailNotTheWholeStream(t *testing.T) {
	res, err := run(t, Spec{
		Script:    script(t, "for i in $(seq 1 5000); do echo \"line $i\"; done\n"),
		TailBytes: 200,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Stdout) > 200 {
		t.Errorf("kept %d bytes with TailBytes=200", len(res.Stdout))
	}
	if !res.StdoutTruncated {
		t.Error("StdoutTruncated is false, so a reader would take the tail for the whole output")
	}
	// The END is what was kept, not the beginning: a failure's last words are the useful ones.
	if !strings.Contains(string(res.Stdout), "line 5000") {
		t.Errorf("the tail does not end at the last line: %q", res.Stdout)
	}
	if strings.Contains(string(res.Stdout), "line 1\n") {
		t.Errorf("the tail still holds the first line, so it is not a tail: %q", res.Stdout)
	}
}

// Forwarding must be complete even when the tail is not: the writer is where the full log goes.
func TestTheWriterSeesEverythingTheTailDropped(t *testing.T) {
	var sb strings.Builder
	res, err := run(t, Spec{
		Script:    script(t, "for i in $(seq 1 2000); do echo \"line $i\"; done\n"),
		Stdout:    &sb,
		TailBytes: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sb.String(), "line 1\n") || !strings.Contains(sb.String(), "line 2000") {
		t.Errorf("the forwarded copy is missing lines; it must be the complete stream")
	}
	if len(res.Stdout) > 100 {
		t.Errorf("the tail is unbounded: %d bytes", len(res.Stdout))
	}
}

func TestTailUnderTheLimitIsKeptWhole(t *testing.T) {
	res, err := run(t, Spec{Script: script(t, "echo short\n"), TailBytes: 4096})
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(res.Stdout)) != "short" || res.StdoutTruncated {
		t.Errorf("Stdout=%q truncated=%v; a small output must survive intact",
			res.Stdout, res.StdoutTruncated)
	}
}

// Unit-level checks on the ring itself: one Write larger than the whole window is the case a
// naive implementation gets wrong (it would keep the front instead of the back, or index out of
// range).
func TestTailKeepsTheLastBytesOfAnOversizedWrite(t *testing.T) {
	tl := &tail{max: 5}
	if _, err := tl.Write([]byte("abcdefghij")); err != nil {
		t.Fatal(err)
	}
	if string(tl.buf) != "fghij" || !tl.truncated {
		t.Errorf("buf=%q truncated=%v, want fghij/true", tl.buf, tl.truncated)
	}
	if _, err := tl.Write([]byte("KL")); err != nil {
		t.Fatal(err)
	}
	if string(tl.buf) != "hijKL" {
		t.Errorf("buf=%q, want hijKL", tl.buf)
	}
}
