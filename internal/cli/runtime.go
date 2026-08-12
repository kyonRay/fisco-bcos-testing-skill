package cli

import (
	"encoding/json"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/cases"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/clusters"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/config"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/engine"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/events"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/execution"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/exitcode"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/paths"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/profile"
	"github.com/kyonRay/fisco-bcos-testing-skill/internal/workspace"
)

// runtime is everything a chain-touching command needs, assembled once.
//
// It exists so the order of the startup steps is written down in ONE place, and that order is not
// arbitrary: configuration resolves before the manifest is read, the manifest is checked before
// any workspace exists, and stale clusters are reclaimed before a reservation is attempted. Each
// step would otherwise leave something behind when the next one fails.
type runtime struct {
	Paths    paths.Paths
	Config   config.Resolved
	Values   map[string]string // every resolved key, including host-only ones
	Manifest engine.Manifest
	Registry *clusters.Registry
	Cases    cases.Registry
	// ProfilePath is the profile resolved to an absolute path. The engine scripts take a PATH, not
	// a logical name: passing "production-enterprise" through makes gate.sh look for a file by that
	// literal name and fail with "profile not found" -- a name the host could have resolved in
	// full, since it already did so to build the configuration.
	ProfilePath string

	Norm *events.Normalizer
	Agg  *exitcode.Aggregator
	Exec *execution.Executor

	// Workspace is created only by commands that build something. `cluster ls` and `doctor` need
	// none, and creating a directory per invocation of a read-only command would fill the state
	// directory with empty runs.
	Workspace workspace.Workspace

	events []events.Event
	stream io.Writer // non-nil in --output jsonl: events go out as they happen
}

// newRuntime resolves configuration and the engine. It creates nothing on disk.
func newRuntime(o GlobalOptions, profileSpec string, stdout, stderr io.Writer) (*runtime, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	p, resolved, err := resolveAll(o, profileSpec, cwd, environMap())
	if err != nil {
		return nil, err
	}
	profilePath := ""
	if profileSpec != "" {
		// resolveAll already resolved this to parse the profile; re-resolving here is cheap and
		// keeps that function returning only what its own name promises.
		if profilePath, err = profile.Resolve(profileSpec, []string{p.Profiles}, cwd); err != nil {
			return nil, err
		}
	}

	// Before anything that could leave state behind: an engine whose protocol this build does not
	// speak cannot be driven, and finding that out with a cluster already up strands it (spec §5).
	m, err := engine.Load(p.EngineJSON)
	if err != nil {
		return nil, err
	}
	if err := m.Check(); err != nil {
		return nil, err
	}
	major, err := m.EventMajor()
	if err != nil {
		return nil, err
	}

	values := make(map[string]string, len(resolved))
	for k, v := range resolved {
		values[k] = v.S
	}

	// In human mode the engine's own output goes to stderr, so stdout stays the command's result.
	// In machine mode it is dropped: engine prose inside a JSON document is precisely what
	// --output json exists to prevent, and the stderr tail still reaches the failure envelope.
	var log io.Writer
	if o.Output == OutputHuman {
		log = stderr
	}

	rt := &runtime{
		Paths:       p,
		Config:      resolved,
		Values:      values,
		Manifest:    m,
		Registry:    clusters.New(p.Clusters),
		Cases:       cases.Registry{Shipped: p.ShippedCases, State: p.StateCases},
		Norm:        &events.Normalizer{ExpectedEventMajor: major},
		Agg:         &exitcode.Aggregator{},
		ProfilePath: profilePath,
	}
	if o.Output == OutputJSONL {
		rt.stream = stdout
	}
	rt.Exec = &execution.Executor{
		Scripts:  p.Scripts,
		RepoRoot: repoRoot(values, p),
		Manifest: m,
		Norm:     rt.Norm,
		Sink:     rt.record,
		Agg:      rt.Agg,
		Log:      log,
	}
	return rt, nil
}

// repoRoot is the engine's working directory (spec §7.3). It falls back to the install root rather
// than to the process working directory: the engine resolves its own relative paths against its
// cwd, so inheriting whatever directory the user happened to be in would make identical commands
// behave differently depending on where they were typed.
func repoRoot(values map[string]string, p paths.Paths) string {
	if v := values["repo.root"]; v != "" {
		return v
	}
	return p.InstallRoot
}

// begin creates this run's workspace and opens the host's run_started event.
func (rt *runtime) begin(extra map[string]interface{}) error {
	id, err := workspace.NewRunID(time.Now())
	if err != nil {
		return err
	}
	ws, err := workspace.Create(rt.Paths.State, id)
	if err != nil {
		return err
	}
	rt.Workspace = ws
	rt.Norm.RunID = id
	if extra == nil {
		extra = map[string]interface{}{}
	}
	extra["workspace"] = ws.Root
	rt.Exec.Start(id, extra)
	return nil
}

// fail reports an error with this run's workspace attached, when there is one. Commands that have
// begun a run use it instead of emitError so the failure envelope carries somewhere to look.
func (rt *runtime) fail(stdout, stderr io.Writer, mode OutputMode, err error) exitcode.Code {
	return emitErrorAt(stdout, stderr, mode, err, rt.Workspace.Root)
}

// record collects every event, and in jsonl mode streams it as it happens. A gate round is long,
// and a consumer that only learns what happened once the process exits cannot show progress.
func (rt *runtime) record(e events.Event) {
	rt.events = append(rt.events, e)
	if rt.stream != nil {
		enc := json.NewEncoder(rt.stream)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(e)
	}
}

// timeout is the run-wide deadline. Zero means none, which is the honest default: no timeout can
// be guessed that is right for both a 3-node smoke round and a full upgrade timeline.
func (rt *runtime) timeout() time.Duration {
	n, err := strconv.Atoi(rt.Values["run.timeout_sec"])
	if err != nil || n <= 0 {
		return 0
	}
	return time.Duration(n) * time.Second
}

// engineConfig is what the engine's environment carries: genesis keys are not registry keys, and
// host-only keys have no environment binding.
func (rt *runtime) engineConfig() map[string]string { return rt.Config.EngineValues() }
