package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/clusters"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/doctor"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/execution"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func init() { commands["cluster"] = clusterCommand }

func clusterCommand(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("cluster needs a subcommand: up, ls or down"))
	}
	switch args[0] {
	case "up":
		return clusterUp(ctx, o, args[1:], stdout, stderr)
	case "ls":
		return clusterList(ctx, o, args[1:], stdout, stderr)
	case "down":
		return clusterDown(ctx, o, args[1:], stdout, stderr)
	}
	return emitError(stdout, stderr, o.Output,
		fbterr.Configf("unknown subcommand %q; cluster takes up, ls or down", args[0]))
}

// UpDoc is what `cluster up` returns. It carries the run id because that is the handle every
// later command needs: `fuzz run --attach`, `cluster down --run-id`, and finding the workspace.
type UpDoc struct {
	Exit      int      `json:"exit"`
	RunID     string   `json:"run_id"`
	Workspace string   `json:"workspace"`
	Profile   string   `json:"profile"`
	Ports     []string `json:"ports"`
	Reason    string   `json:"reason,omitempty"`
}

// clusterUp builds a cluster and LEAVES IT RUNNING.
//
// Without it the only command that builds a chain is `gate run`, which tears its cluster down on
// the way out -- so nothing could produce a cluster for `fuzz run --attach` to attach to, and the
// flag was unusable. It is also what makes an upgrade timeline debuggable: rebuilding a chain for
// every attempt costs a full build_chain each time.
//
// The reservation is deliberately NOT released at the end. That entry is the record that these
// ports are taken, and it lives until `cluster down` removes it.
func clusterUp(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("cluster up", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var profileSpec string
	var parallel bool
	fs.StringVar(&profileSpec, "p", "production-enterprise", "profile name or path")
	fs.BoolVar(&parallel, "allow-parallel", false,
		"allow a second cluster, if its port ranges do not overlap")
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, profileSpec, stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	// Everything refusable without side effects, refused first -- same order as gate run. Each of
	// these after a chain is up would strand it.
	plan, err := doctor.Plan("cluster-up", nil)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if _, err := doctor.CheckIn(rt.Exec.RepoRoot, plan, rt.Values, doctor.OSProbe{}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	ports, err := derivePorts(rt.Values)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if err := clusters.CheckFree(ports); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if _, err := rt.Registry.Reclaim(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	if err := rt.begin(map[string]interface{}{"profile": profileSpec, "command": "cluster up"}); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}
	if _, err := rt.Registry.Reserve(clusters.Entry{
		RunID:     rt.Norm.RunID,
		Workspace: rt.Workspace.Cluster,
		Profile:   profileSpec,
		Ports:     ports,
	}, parallel); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}

	res := rt.Exec.Run(ctx, execution.Command{
		Script:   "apply_profile.sh",
		Args:     []string{"-p", rt.ProfilePath, "-o", rt.Workspace.Cluster},
		Requires: []string{"cluster"},
		Config:   rt.engineConfig(),
		Timeout:  rt.timeout(),
	})
	code := rt.Agg.Result()
	rt.Exec.Finish(code)

	// Record which processes the cluster actually started. Registering with no nodes leaves the
	// entry permanently "unknown": it can never be seen as active, never found stale, and never
	// reclaimed after a crash -- the whole liveness apparatus sits behind an empty slice.
	if code == exitcode.OK {
		if nodes := clusters.DiscoverNodes(rt.Workspace.Cluster, clusters.OSProber{}); len(nodes) > 0 {
			entry, err := rt.Registry.Resolve(rt.Norm.RunID, "")
			if err == nil {
				entry.Nodes = nodes
				if err := rt.Registry.Update(entry); err != nil {
					return rt.fail(stdout, stderr, o.Output, err)
				}
			}
		}
	}

	doc := UpDoc{
		Exit: code.Int(), RunID: rt.Norm.RunID, Workspace: rt.Workspace.Cluster,
		Profile: profileSpec, Ports: portStrings(ports), Reason: res.Reason,
	}
	if code != exitcode.OK {
		// A half-built cluster keeps its reservation: something may still be listening, and
		// handing those ports to the next run would collide with it. `cluster down` is the way out,
		// and the message has to say so or the entry looks like a leak.
		if err := render(stdout, o.Output, doc, func(w io.Writer) {
			fmt.Fprintf(w, "cluster %s FAILED to come up (exit %d)\n  %s\n", doc.RunID, doc.Exit, doc.Reason)
			fmt.Fprintf(w, "  its ports stay reserved; release them with:\n"+
				"    fbt cluster down --run-id %s\n", doc.RunID)
		}); err != nil {
			return rt.fail(stdout, stderr, o.Output, err)
		}
		return code
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		fmt.Fprintf(w, "cluster %s is up\n  %s\n  %s\n", doc.RunID, doc.Workspace, portList(ports))
		fmt.Fprintf(w, "\n  attach a fuzz run:  fbt fuzz run --attach %s\n", doc.RunID)
		fmt.Fprintf(w, "  stop it:            fbt cluster down --run-id %s\n", doc.RunID)
	}); err != nil {
		return rt.fail(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

func portStrings(rs []clusters.PortRange) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.String())
	}
	return out
}

type clusterDoc struct {
	Clusters  []clusters.Entry `json:"clusters"`
	Reclaimed []string         `json:"reclaimed,omitempty"`
}

// clusterList shows what is registered, reclaiming crash leftovers on the way.
//
// The reclamation is reported rather than done silently: an operator who sees three clusters
// vanish from the listing has to be able to tell "fbt cleaned up after a crash" from "somebody
// else tore down my chain".
func clusterList(_ context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("cluster ls", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, "", stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	reclaimed, err := rt.Registry.Reclaim()
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	list, err := rt.Registry.List()
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	doc := clusterDoc{Clusters: list}
	for _, e := range reclaimed {
		doc.Reclaimed = append(doc.Reclaimed, e.RunID)
	}
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		for _, id := range doc.Reclaimed {
			fmt.Fprintf(w, "reclaimed stale cluster %s (its nodes are gone)\n", id)
		}
		if len(list) == 0 {
			fmt.Fprintln(w, "no clusters are registered")
			return
		}
		for _, e := range list {
			fmt.Fprintf(w, "%-28s %-9s %s\n  %s\n", e.RunID, e.Status, e.Workspace, portList(e.Ports))
		}
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}

func portList(rs []clusters.PortRange) string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.String())
	}
	return strings.Join(out, " ")
}

type downDoc struct {
	Exit      int    `json:"exit"`
	RunID     string `json:"run_id"`
	Workspace string `json:"workspace"`
	Outcome   string `json:"outcome"`
}

// clusterDown stops one cluster and releases its reservation.
//
// It runs NO dependency check (spec §5). A half-installed machine with a stuck cluster is exactly
// when teardown has to work, and refusing it because Viem is missing leaves ports held by a chain
// nobody can now stop.
func clusterDown(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	fs := flag.NewFlagSet("cluster down", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	finish := RegisterGlobalFlags(fs, &o)
	var runID, ws string
	var keep bool
	fs.StringVar(&runID, "run-id", "", "the run to stop")
	fs.StringVar(&ws, "workspace", "", "the workspace to stop")
	fs.BoolVar(&keep, "keep-registration", false,
		"stop the nodes but leave the registry entry in place")
	if err := fs.Parse(args); err != nil {
		return emitError(stdout, stderr, o.Output, fbterr.Configf("%v", err))
	}
	if err := finish(); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	rt, err := newRuntime(o, "", stdout, stderr)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	// Resolve refuses to guess between several active clusters. Guessing here tears down somebody
	// else's investigation on a shared machine.
	entry, err := rt.Registry.Resolve(runID, ws)
	if err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}

	doc := downDoc{RunID: entry.RunID, Workspace: entry.Workspace, Outcome: "stopped"}
	if entry.Status != clusters.StatusStale {
		res := rt.Exec.Run(ctx, execution.Command{
			Script:   "cluster_down.sh",
			Args:     []string{"-o", entry.Workspace},
			Requires: []string{"cluster"},
			Config:   rt.engineConfig(),
			Timeout:  rt.timeout(),
		})
		if res.Err != nil {
			// The nodes may be half down. The registration deliberately stays, so the next run is
			// refused rather than colliding with whatever is still listening.
			return emitError(stdout, stderr, o.Output, res.Err)
		}
	} else {
		doc.Outcome = "already stopped"
	}
	if !keep {
		if err := rt.Registry.Release(entry.RunID); err != nil {
			return emitError(stdout, stderr, o.Output, err)
		}
	}
	doc.Exit = 0
	if err := render(stdout, o.Output, doc, func(w io.Writer) {
		fmt.Fprintf(w, "cluster %s: %s\n", doc.RunID, doc.Outcome)
	}); err != nil {
		return emitError(stdout, stderr, o.Output, err)
	}
	return exitcode.OK
}
