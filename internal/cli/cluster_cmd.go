package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/clusters"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/execution"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/fbterr"
)

func init() { commands["cluster"] = clusterCommand }

func clusterCommand(ctx context.Context, o GlobalOptions, args []string, stdout, stderr io.Writer) exitcode.Code {
	if len(args) == 0 {
		return emitError(stdout, stderr, o.Output,
			fbterr.Configf("cluster needs a subcommand: ls or down"))
	}
	switch args[0] {
	case "ls":
		return clusterList(ctx, o, args[1:], stdout, stderr)
	case "down":
		return clusterDown(ctx, o, args[1:], stdout, stderr)
	}
	return emitError(stdout, stderr, o.Output,
		fbterr.Configf("unknown subcommand %q; cluster takes ls or down", args[0]))
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
