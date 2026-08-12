// Command fbt drives the FISCO-BCOS release gate: it owns configuration, dispatch and the output
// contract, and runs the bash engine as a subprocess.
//
// main does nothing but hand the arguments to cli.Dispatch and exit with the code it returns. All
// behaviour lives in packages that write to injected streams, so every path is exercised in
// memory by tests rather than by running the binary.
package main

import (
	"os"

	"github.com/kyonRay/fisco-bcos-testing-skill/internal/cli"
)

func main() {
	os.Exit(cli.Dispatch(os.Args[1:], os.Stdout, os.Stderr).Int())
}
