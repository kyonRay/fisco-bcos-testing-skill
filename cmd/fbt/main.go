// Command fbt drives the FISCO-BCOS release gate: it owns configuration, dispatch and the output
// contract, and runs the bash engine as a subprocess.
//
// main does nothing but install the signal handling and hand the arguments to cli.Dispatch. All
// behaviour lives in packages that write to injected streams, so every path is exercised in memory
// by tests rather than by running the binary.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/cli"
)

func main() {
	// The first interrupt cancels the context: fbt then brings the engine's process group down
	// cleanly and exits 130, rather than leaving a half-built cluster and orphaned node processes
	// behind (spec §10).
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The SECOND interrupt must kill fbt outright. Once stop() has restored the default
	// disposition, another ^C terminates the process immediately -- so a cleanup that itself hangs
	// can never trap the user in a program that refuses to quit.
	go func() {
		<-ctx.Done()
		stop()
	}()

	os.Exit(cli.Dispatch(ctx, os.Args[1:], os.Stdout, os.Stderr).Int())
}
