package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/cases"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/clusters"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/doctor"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/events"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/execution"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func init() {
	commands["gate"] = gateCommand
	commands["plan"] = planCommand
}

func gateCommand(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 || args[0] != "run" {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("gate takes one subcommand: run"))
	}
	return gateRun(ctx, o, args[1:], stdout, stderr)
}

// gateOptions are the flags shared by `gate run` and `plan`, so the plan is guaranteed to describe
// the run it claims to.
type gateOptions struct {
	profile   string
	scenarios string
	failFast  bool
	parallel  bool
	skipCases bool
}

func (g *gateOptions) bind(fs *flag.FlagSet) {
	fs.StringVar(&g.profile, "p", "production-enterprise", "profile name or path")
	fs.StringVar(&g.scenarios, "scenarios", "", "comma-separated scenario families (default: all)")
	fs.BoolVar(&g.failFast, "fail-fast", false, "stop at the first gate failure too")
	fs.BoolVar(&g.parallel, "allow-parallel", false,
		"allow a second cluster, if its port ranges do not overlap")
	fs.BoolVar(&g.skipCases, "no-cases", false, "run the scenarios only, skip the .case sweep")
}

// GateDoc is spec §8's success document. UI and CI build against this shape.
type GateDoc struct {
	Exit      int          `json:"exit"`
	RunID     string       `json:"run_id"`
	Workspace string       `json:"workspace"`
	Profile   string       `json:"profile"`
	Scenarios []stageEntry `json:"scenarios"`
	Cases     []stageEntry `json:"cases"`
	Oracles   []oracleHit  `json:"oracles"`
	Reason    string       `json:"reason,omitempty"`
}

type stageEntry struct {
	Name   string `json:"name"`
	Result string `json:"result"`
	Skip   string `json:"skip_reason,omitempty"`
}

type oracleHit struct {
	Oracle  string `json:"oracle"`
	Phase   string `json:"phase,omitempty"`
	Verdict string `json:"verdict"`
}

// gateRun is the whole sweep: dependency check, port reservation, the scenario families, then the
// .case fixtures.
func gateRun(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("gate run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var g gateOptions
	g.bind(fs)
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, g.profile, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	selected := splitList(g.scenarios)

	// 1. Everything that can be refused without side effects, refused first. Each of these leaves
	// nothing behind, and every one of them AFTER a cluster is up would strand it.
	plan, err := doctor.Plan("gate", selected)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if _, err := doctor.CheckIn(rt.Exec.RepoRoot, plan, rt.Values, doctor.OSProbe{}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	// Every .case parses before anything starts, so one typo is a message rather than a failure
	// discovered with a chain already running (spec §6.4).
	allCases, err := rt.Cases.List()
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	sweep := cases.Sweep(allCases)
	if g.skipCases {
		sweep = nil
	}
	ports, err := derivePorts(rt.Values)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	// 2. Reclaim crash leftovers, then reserve. In that order: a run refused because a machine
	// crashed last week would be a permanent block with no way to see why.
	if _, err := rt.Registry.Reclaim(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if err := rt.begin(map[string]interface{}{"profile": g.profile}); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}
	if _, err := rt.Registry.Reserve(clusters.Entry{
		RunID:     rt.Norm.RunID,
		Workspace: rt.Workspace.Cluster,
		Profile:   g.profile,
		Ports:     ports,
	}, g.parallel); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}
	// The reservation is released here rather than by gate.sh: the engine tears the cluster down,
	// but only the host knows the run id the entry is filed under.
	defer func() { _ = rt.Registry.Release(rt.Norm.RunID) }()

	doc := GateDoc{RunID: rt.Norm.RunID, Workspace: rt.Workspace.Root, Profile: g.profile}

	// 3. Stage one: the scenario families.
	gateArgs := []string{"-p", rt.ProfilePath, "-o", rt.Workspace.Cluster}
	if len(selected) > 0 {
		gateArgs = append(gateArgs, "--scenarios", strings.Join(selected, ","))
	}
	first := rt.Exec.Run(ctx, execution.Command{
		Script:   "gate.sh",
		Args:     gateArgs,
		Requires: []string{"gate"},
		Config:   rt.engineConfig(),
		Timeout:  rt.timeout(),
	})

	// 4. Stage two: the .case sweep, subject to the continue policy.
	for _, c := range sweep {
		if stop, why := stopSweep(rt.Agg.Result(), g.failFast); stop {
			doc.Cases = append(doc.Cases, stageEntry{Name: c.Name, Result: "skip", Skip: why})
			continue
		}
		rt.Exec.Run(ctx, execution.Command{
			Script:   "run_case.sh",
			Args:     []string{c.Path, "-o", rt.Workspace.Cluster},
			Requires: []string{"case"},
			Config:   rt.engineConfig(),
			Timeout:  rt.timeout(),
		})
	}

	code := rt.Agg.Result()
	rt.Exec.Finish(code)

	// The report is derived from the normalized event stream, not assembled alongside it. A second
	// source of truth here is how a summary comes to disagree with the events it summarizes.
	doc.Exit = code.Int()
	doc.Scenarios = collectStages(rt.events, "scenario_finished", "name", "result")
	doc.Cases = append(doc.Cases, collectStages(rt.events, "case_replayed", "file", "result")...)
	doc.Oracles = collectOracles(rt.events)
	if first.Reason != "" {
		doc.Reason = first.Reason
	}

	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		writeGateHuman(w, doc)
	}); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}
	return code
}

// stopSweep implements spec §10's continue policy.
//
// A gate failure is a RESULT, and stopping at the first one throws away the rest of the picture
// the operator came for. A 20/30/40 is different: the configuration, the machine or fbt itself is
// broken, so every later case would be measuring something other than the chain.
func stopSweep(worst exitcode.Code, failFast bool) (bool, string) {
	switch worst {
	case exitcode.Config, exitcode.Infra, exitcode.Host, exitcode.Canceled:
		return true, "earlier_" + strings.ToLower(worst.String())
	case exitcode.GateFail:
		if failFast {
			return true, "fail_fast"
		}
	}
	return false, ""
}

func collectStages(evs []events.Event, name, keyField, resultField string) []stageEntry {
	var out []stageEntry
	for _, e := range evs {
		if e.Ev != name {
			continue
		}
		out = append(out, stageEntry{
			Name:   payloadString(e, keyField),
			Result: payloadString(e, resultField),
			Skip:   payloadString(e, "skip_reason"),
		})
	}
	return out
}

// collectOracles keeps only the trips. A clean round produces one oracle_check per oracle per
// phase, and listing every one of them buries the handful that matter.
func collectOracles(evs []events.Event) []oracleHit {
	var out []oracleHit
	for _, e := range evs {
		switch e.Ev {
		case "oracle_check":
			if payloadString(e, "verdict") != "trip" {
				continue
			}
			out = append(out, oracleHit{
				Oracle: payloadString(e, "oracle"), Phase: payloadString(e, "phase"),
				Verdict: "trip",
			})
		case "trip":
			out = append(out, oracleHit{Oracle: payloadString(e, "oracle"), Verdict: "trip"})
		}
	}
	return out
}

func payloadString(e events.Event, field string) string {
	if v, ok := e.Payload[field].(string); ok {
		return v
	}
	return ""
}

func writeGateHuman(w io.Writer, doc GateDoc) {
	fmt.Fprintf(w, "run %s  profile %s\n%s\n\n", doc.RunID, doc.Profile, doc.Workspace)
	for _, s := range doc.Scenarios {
		fmt.Fprintf(w, "  scenario %-14s %s %s\n", s.Name, s.Result, s.Skip)
	}
	for _, c := range doc.Cases {
		fmt.Fprintf(w, "  case     %-14s %s %s\n", c.Name, c.Result, c.Skip)
	}
	for _, o := range doc.Oracles {
		fmt.Fprintf(w, "  ORACLE TRIP: %s %s\n", o.Oracle, o.Phase)
	}
	if doc.Exit == 0 {
		fmt.Fprintf(w, "\nGATE: PASS\n")
		return
	}
	fmt.Fprintf(w, "\nGATE: FAIL (exit %d) %s\n", doc.Exit, doc.Reason)
}

// derivePorts reads the cluster's port bases out of the resolved configuration. The registry needs
// them BEFORE the chain exists, because a reservation made after the ports are bound reserves
// nothing.
func derivePorts(values map[string]string) ([]clusters.PortRange, error) {
	n, err := intValue(values, "cluster.node_count", 4)
	if err != nil {
		return nil, err
	}
	p2p, err := intValue(values, "cluster.p2p_base_port", 30300)
	if err != nil {
		return nil, err
	}
	rpc, err := intValue(values, "cluster.bcos_base_port", 20200)
	if err != nil {
		return nil, err
	}
	web3, err := intValue(values, "cluster.web3_base_port", 8545)
	if err != nil {
		return nil, err
	}
	return clusters.DerivePorts(n, p2p, rpc, web3)
}

func intValue(values map[string]string, key string, fallback int) (int, error) {
	raw, ok := values[key]
	if !ok || raw == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fbterr.Configf("%s = %q is not a number", key, raw)
	}
	return n, nil
}

// PlanDoc is what `fbt plan` prints: everything the run would do, with nothing started.
type PlanDoc struct {
	Profile   string               `json:"profile"`
	Scenarios []string             `json:"scenarios"`
	Cases     []planCase           `json:"cases"`
	Ports     []clusters.PortRange `json:"ports"`
	Deps      []string             `json:"required_deps"`
}

type planCase struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Swept  bool   `json:"swept"`
	Reason string `json:"reason,omitempty"`
}

// planCommand answers "what would `gate run` actually do" without touching anything.
//
// It lists the SKIPPED cases too, with why. A plan that shows only what runs cannot answer the
// question people actually bring to it -- "why isn't my fixture being tested" -- which is the
// question a status field silently answers wrong when nobody can see it.
func planCommand(_ context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("plan", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var g gateOptions
	g.bind(fs)
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, g.profile, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	selected := splitList(g.scenarios)
	if len(selected) == 0 {
		selected = []string{"ut", "dual_rpc", "malformed", "jsd"}
	}
	all, err := rt.Cases.List()
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	ports, err := derivePorts(rt.Values)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	deps, err := doctor.Plan("gate", splitList(g.scenarios))
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	doc := PlanDoc{Profile: g.profile, Scenarios: selected, Ports: ports}
	for _, d := range deps {
		doc.Deps = append(doc.Deps, d.Name)
	}
	for _, c := range all {
		pc := planCase{Name: c.Name, Status: string(c.Status), Swept: c.Sweepable() && !g.skipCases}
		switch {
		case g.skipCases:
			pc.Reason = "--no-cases"
		case c.Status == cases.StatusPending:
			pc.Reason = "pending: the defect is not fixed, so a sweep would be permanently red"
		case c.Status == cases.StatusExample:
			pc.Reason = "example: a format demonstration, never swept"
		}
		doc.Cases = append(doc.Cases, pc)
	}

	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		fmt.Fprintf(w, "profile:   %s\nscenarios: %s\nports:     %s\n\n",
			doc.Profile, strings.Join(doc.Scenarios, ", "), portList(doc.Ports))
		for _, c := range doc.Cases {
			mark := "skip"
			if c.Swept {
				mark = "run "
			}
			fmt.Fprintf(w, "  %s %-24s %s\n", mark, c.Name, c.Reason)
		}
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}
