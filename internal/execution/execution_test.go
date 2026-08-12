package execution

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/engine"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/events"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/testinstall"
)

// harness builds a real install tree with a real Executor over it. The scripts are stand-ins that
// speak the real fd 3 protocol -- these tests exercise the adapter, not the gate.
type harness struct {
	inst testinstall.Install
	ex   *Executor
	agg  *exitcode.Aggregator
	evs  *[]events.Event
	log  *strings.Builder
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	inst := testinstall.New(t)
	m, err := engine.Load(inst.Root + "/libexec/fbt/engine.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Check(); err != nil {
		t.Fatal(err)
	}
	major, err := m.EventMajor()
	if err != nil {
		t.Fatal(err)
	}
	var evs []events.Event
	var log strings.Builder
	agg := &exitcode.Aggregator{}
	return &harness{
		inst: inst, agg: agg, evs: &evs, log: &log,
		ex: &Executor{
			Scripts:  inst.Scripts(),
			RepoRoot: inst.Root,
			Manifest: m,
			Norm:     &events.Normalizer{RunID: "run-1", ExpectedEventMajor: major},
			Sink:     func(e events.Event) { evs = append(evs, e) },
			Agg:      agg,
			Log:      &log,
		},
	}
}

// emitter returns a script body that speaks the protocol by hand, so a test can produce event
// sequences the real event_lib.sh would never produce -- including the broken ones.
func emit(ev string, pairs ...string) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, `printf '{"schema_version":"1.0.0","ev":"%s"`, ev)
	for i := 0; i+1 < len(pairs); i += 2 {
		fmt.Fprintf(&sb, `,"%s":%s`, pairs[i], pairs[i+1])
	}
	sb.WriteString("}\\n' >&3\n")
	return sb.String()
}

func (h *harness) run(t *testing.T, name, body string, c Command) Result {
	t.Helper()
	h.inst.WriteScript(t, name, body)
	c.Script = name
	if c.Timeout == 0 {
		c.Timeout = 30 * time.Second
	}
	return h.ex.Run(context.Background(), c)
}

func (h *harness) names() []string {
	out := make([]string, 0, len(*h.evs))
	for _, e := range *h.evs {
		out = append(out, e.Ev)
	}
	return out
}

// ---------------------------------------------------------------------------
// The happy path, and the shape of everything around it.
// ---------------------------------------------------------------------------

func TestACleanCommandPassesAndFeedsTheAggregate(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "ok.sh",
		emit("command_started", "cmd", `"ok.sh"`)+
			"echo working\n"+
			emit("command_finished", "cmd", `"ok.sh"`, "outcome", `"pass"`, "engine_exit", "0"),
		Command{})
	if r.Code != exitcode.OK || r.Err != nil {
		t.Fatalf("Code=%v Err=%v Reason=%q", r.Code, r.Err, r.Reason)
	}
	if r.Outcome != "pass" || r.EngineExit != 0 {
		t.Errorf("Outcome=%q EngineExit=%d", r.Outcome, r.EngineExit)
	}
	if h.agg.Result() != exitcode.OK {
		t.Errorf("aggregate = %v", h.agg.Result())
	}
	if !strings.Contains(h.log.String(), "working") {
		t.Errorf("the engine's stdout never reached the log writer: %q", h.log.String())
	}
	// engine_exit must have survived as a number, not been re-read as a string or lost.
	if got := h.names(); len(got) != 2 {
		t.Errorf("events = %v, want the two protocol events", got)
	}
}

func TestHostBracketingEventsShareTheCommandSequence(t *testing.T) {
	h := newHarness(t)
	h.ex.Start("run-1", nil)
	h.run(t, "ok.sh",
		emit("command_started", "cmd", `"ok.sh"`)+
			emit("command_finished", "cmd", `"ok.sh"`, "outcome", `"pass"`, "engine_exit", "0"),
		Command{})
	h.ex.Finish(exitcode.OK)

	want := []string{"run_started", "command_started", "command_finished", "run_finished"}
	got := h.names()
	if len(got) != 4 {
		t.Fatalf("events = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] || (*h.evs)[i].Seq != int64(i+1) {
			t.Errorf("event %d = %s seq=%d, want %s seq=%d",
				i, got[i], (*h.evs)[i].Seq, want[i], i+1)
		}
	}
}

// ---------------------------------------------------------------------------
// Outcome mapping. The terminator is authoritative (spec §8).
// ---------------------------------------------------------------------------

func TestEveryOutcomeMapsToItsExitCode(t *testing.T) {
	for _, tc := range []struct {
		outcome string
		exit    int
		want    exitcode.Code
		wantErr bool
	}{
		{"pass", 0, exitcode.OK, false},
		{"gate_fail", 1, exitcode.GateFail, false}, // a verdict, not an fbt error
		{"config_error", 2, exitcode.Config, true},
		{"infra_error", 1, exitcode.Infra, true},
		{"engine_error", 3, exitcode.Host, true},
	} {
		h := newHarness(t)
		r := h.run(t, "x.sh",
			emit("command_started", "cmd", `"x.sh"`)+
				emit("command_finished", "cmd", `"x.sh"`, "outcome", `"`+tc.outcome+`"`,
					"engine_exit", fmt.Sprint(tc.exit))+
				fmt.Sprintf("exit %d\n", tc.exit),
			Command{})
		if r.Code != tc.want {
			t.Errorf("%s: Code=%v, want %v (reason %q)", tc.outcome, r.Code, tc.want, r.Reason)
		}
		if (r.Err != nil) != tc.wantErr {
			t.Errorf("%s: Err=%v, wantErr=%v", tc.outcome, r.Err, tc.wantErr)
		}
		if tc.want != exitcode.OK && r.Reason == "" {
			t.Errorf("%s: a failure with no reason gives the user nothing to act on", tc.outcome)
		}
	}
}

// The single most important assertion in this package. An engine that says "pass" while exiting
// non-zero is a false green, and taking its word for it is how a broken release ships.
func TestPassAlongsideANonZeroExitIsRefused(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "liar.sh",
		emit("command_started", "cmd", `"liar.sh"`)+
			emit("command_finished", "cmd", `"liar.sh"`, "outcome", `"pass"`, "engine_exit", "0")+
			"exit 5\n",
		Command{})
	if r.Code != exitcode.Host {
		t.Fatalf("Code=%v, want 40: a pass verdict contradicted by exit 5 must not be trusted", r.Code)
	}
	if !strings.Contains(r.Reason, "contradicts") {
		t.Errorf("Reason=%q; it must name the contradiction", r.Reason)
	}
	if h.agg.Result() != exitcode.Host {
		t.Errorf("aggregate = %v, want 40", h.agg.Result())
	}
}

// ---------------------------------------------------------------------------
// Protocol breaches. All 40: the engine and the host disagree, which is a bug in one of them.
// ---------------------------------------------------------------------------

func TestAMissingTerminatorIsAHostError(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "silent.sh",
		emit("command_started", "cmd", `"silent.sh"`)+"exit 3\n", Command{})
	if r.Code != exitcode.Host || !strings.Contains(r.Reason, "command_finished") {
		t.Errorf("Code=%v Reason=%q, want 40 naming the missing terminator", r.Code, r.Reason)
	}
	if r.Outcome != "" {
		t.Errorf("Outcome=%q; there was none to report", r.Outcome)
	}
}

// SIGKILL cannot be caught, so the engine emits nothing -- the exact condition spec §9 reads as
// "the subprocess died unexpectedly".
func TestAKilledEngineWithNoTerminatorIsAHostError(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "suicide.sh",
		emit("command_started", "cmd", `"suicide.sh"`)+"kill -9 $$\n", Command{})
	if r.Code != exitcode.Host || !strings.Contains(r.Reason, "signal") {
		t.Errorf("Code=%v Reason=%q, want 40 naming the signal", r.Code, r.Reason)
	}
}

func TestTwoTerminatorsAreABreach(t *testing.T) {
	h := newHarness(t)
	fin := emit("command_finished", "cmd", `"twice.sh"`, "outcome", `"pass"`, "engine_exit", "0")
	r := h.run(t, "twice.sh", emit("command_started", "cmd", `"twice.sh"`)+fin+fin, Command{})
	if r.Code != exitcode.Host || !strings.Contains(r.Reason, "twice") {
		t.Errorf("Code=%v Reason=%q, want 40 naming the duplicate", r.Code, r.Reason)
	}
}

func TestAWrapperThatDoesNotNameItselfIsABreach(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "real.sh",
		emit("command_started", "cmd", `"something-else.sh"`)+
			emit("command_finished", "cmd", `"something-else.sh"`, "outcome", `"pass"`,
				"engine_exit", "0"),
		Command{})
	if r.Code != exitcode.Host {
		t.Errorf("Code=%v, want 40: the terminator cannot be matched to what we launched", r.Code)
	}
}

func TestAnUnparseableEventStreamIsAHostError(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "garbage.sh",
		emit("command_started", "cmd", `"garbage.sh"`)+"printf 'not json\\n' >&3\n"+
			emit("command_finished", "cmd", `"garbage.sh"`, "outcome", `"pass"`, "engine_exit", "0"),
		Command{})
	if r.Code != exitcode.Host {
		t.Errorf("Code=%v, want 40", r.Code)
	}
}

func TestAnUnknownOutcomeWordIsAHostError(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "future.sh",
		emit("command_started", "cmd", `"future.sh"`)+
			emit("command_finished", "cmd", `"future.sh"`, "outcome", `"quarantined"`,
				"engine_exit", "0"),
		Command{})
	if r.Code != exitcode.Host || !strings.Contains(r.Reason, "quarantined") {
		t.Errorf("Code=%v Reason=%q, want 40 naming the word it does not understand", r.Code, r.Reason)
	}
}

// ---------------------------------------------------------------------------
// Nesting. gate.sh launches apply_profile.sh, which inherits fd 3 and emits its own pair.
// ---------------------------------------------------------------------------

func TestANestedCommandsTerminatorIsNotTheOuterOne(t *testing.T) {
	h := newHarness(t)
	h.inst.WriteScript(t, "inner.sh",
		emit("command_started", "cmd", `"inner.sh"`)+
			emit("command_finished", "cmd", `"inner.sh"`, "outcome", `"pass"`, "engine_exit", "0"))
	r := h.run(t, "outer.sh",
		emit("command_started", "cmd", `"outer.sh"`)+
			`"$(dirname "$0")/inner.sh"`+"\n"+
			emit("command_finished", "cmd", `"outer.sh"`, "outcome", `"gate_fail"`, "engine_exit", "1")+
			"exit 1\n",
		Command{})
	// The inner pass must not have terminated the outer command, and the outer gate_fail must win.
	if r.Code != exitcode.GateFail {
		t.Fatalf("Code=%v Reason=%q, want 10 from the OUTER command's own verdict", r.Code, r.Reason)
	}
	if got := h.names(); len(got) != 4 {
		t.Errorf("events = %v, want both nested pairs", got)
	}
}

// A nested script KILLed mid-run leaves its frame open forever. Reporting fbt's own bug for that
// would be wrong, but saying nothing would hide it.
func TestAnAbandonedNestedFrameIsReportedNotFatal(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "outer.sh",
		emit("command_started", "cmd", `"outer.sh"`)+
			emit("command_started", "cmd", `"vanished.sh"`)+
			emit("command_finished", "cmd", `"outer.sh"`, "outcome", `"gate_fail"`, "engine_exit", "1")+
			"exit 1\n",
		Command{})
	if r.Code != exitcode.GateFail {
		t.Fatalf("Code=%v, want the outer command's own verdict to still stand", r.Code)
	}
	if !strings.Contains(r.Reason, "vanished.sh") {
		t.Errorf("Reason=%q; the nested command that never finished must be named", r.Reason)
	}
}

// ---------------------------------------------------------------------------
// Deadline and cancellation.
// ---------------------------------------------------------------------------

// The timeout verdict must survive the host's own kill. Without this, a chain that stopped
// answering (30, "fix the test machine") is reported as fbt having a bug (40).
func TestADeadlineIsInfraNotAHostBug(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "hang.sh",
		emit("command_started", "cmd", `"hang.sh"`)+"sleep 30\n",
		Command{Timeout: 3 * time.Second})
	if r.Code != exitcode.Infra {
		t.Fatalf("Code=%v Reason=%q, want 30", r.Code, r.Reason)
	}
	if !r.Runner.TimedOut {
		t.Error("the result does not record that the host itself brought the process down")
	}
	if h.agg.Result() != exitcode.Infra {
		t.Errorf("aggregate = %v, want 30: the signal death must not have overwritten it",
			h.agg.Result())
	}
}

// The same, but the TERM lands mid-write so fd 3 ends on a truncated line. Blaming the engine for
// output the host itself cut off would turn every timeout into a 40.
func TestATruncatedEventLineDuringATimeoutStaysInfra(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "chatty.sh",
		emit("command_started", "cmd", `"chatty.sh"`)+
			`printf '{"schema_version":"1.0.0","ev":"trip"' >&3`+"\n"+ // deliberately unterminated
			"sleep 30\n",
		Command{Timeout: 3 * time.Second})
	if r.Code != exitcode.Infra {
		t.Errorf("Code=%v Reason=%q, want 30", r.Code, r.Reason)
	}
}

func TestCancellationIs130AndOutranksEverything(t *testing.T) {
	h := newHarness(t)
	h.agg.Add(exitcode.Host) // a real host error already recorded this run
	ctx, cancel := context.WithCancel(context.Background())
	h.inst.WriteScript(t, "wait.sh", emit("command_started", "cmd", `"wait.sh"`)+"sleep 30\n")
	go func() { time.Sleep(2 * time.Second); cancel() }()
	r := h.ex.Run(ctx, Command{Script: "wait.sh", Timeout: 30 * time.Second})
	if r.Code != exitcode.Canceled {
		t.Fatalf("Code=%v Reason=%q, want 130", r.Code, r.Reason)
	}
	if h.agg.Result() != exitcode.Canceled {
		t.Errorf("aggregate = %v, want 130 to outrank the recorded host error", h.agg.Result())
	}
}

// ---------------------------------------------------------------------------
// Everything that must fail BEFORE a process exists (spec §5).
// ---------------------------------------------------------------------------

func TestAMissingCapabilityIsRefusedBeforeAnythingStarts(t *testing.T) {
	h := newHarness(t)
	started := h.inst.Root + "/started"
	r := h.run(t, "cap.sh", "touch "+started+"\n",
		Command{Requires: []string{"time-travel"}})
	if r.Code != exitcode.Host || !strings.Contains(r.Reason, "time-travel") {
		t.Errorf("Code=%v Reason=%q", r.Code, r.Reason)
	}
	if fileExists(started) {
		t.Error("the script RAN; a capability check that fires after the process starts can " +
			"strand a live cluster")
	}
}

func TestADeclaredCapabilityIsAccepted(t *testing.T) {
	h := newHarness(t)
	r := h.run(t, "cap.sh",
		emit("command_started", "cmd", `"cap.sh"`)+
			emit("command_finished", "cmd", `"cap.sh"`, "outcome", `"pass"`, "engine_exit", "0"),
		Command{Requires: []string{"gate", "ut"}})
	if r.Code != exitcode.OK {
		t.Errorf("Code=%v Reason=%q", r.Code, r.Reason)
	}
}

// The script name is a NAME. Accepting a path would let a caller point fbt at any executable on
// the machine and still get the engine's process group, stripped environment and event handling.
func TestAScriptPathIsRefused(t *testing.T) {
	h := newHarness(t)
	for _, name := range []string{"../evil.sh", "/bin/sh", "sub/dir.sh"} {
		r := h.ex.Run(context.Background(), Command{Script: name})
		if r.Code != exitcode.Host {
			t.Errorf("%q: Code=%v, want 40", name, r.Code)
		}
	}
}

func TestAnAbsentScriptIsAnInfraError(t *testing.T) {
	h := newHarness(t)
	r := h.ex.Run(context.Background(), Command{Script: "nope.sh"})
	if r.Code != exitcode.Infra {
		t.Errorf("Code=%v Reason=%q, want 30", r.Code, r.Reason)
	}
	if c, ok := fbterr.ClassOf(r.Err); !ok || c != fbterr.ClassInfra {
		t.Errorf("Err class = %v; the envelope would carry the wrong class", c)
	}
}

// A bad config VALUE must be refused before bash sees it (spec §11).
func TestABadConfigValueNeverReachesTheEngine(t *testing.T) {
	h := newHarness(t)
	marker := h.inst.Root + "/ran"
	r := h.run(t, "cfg.sh", "touch "+marker+"\n",
		Command{Config: map[string]string{"cluster.node_count": "not-a-number"}})
	if r.Code != exitcode.Config {
		t.Errorf("Code=%v Reason=%q, want 20", r.Code, r.Reason)
	}
	if fileExists(marker) {
		t.Error("the engine ran with an invalid configuration value")
	}
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }
