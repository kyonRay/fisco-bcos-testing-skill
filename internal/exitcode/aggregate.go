package exitcode

import "sync"

// normalize forces any value into the six-code vocabulary. Without it, Add(Code(99)) would make
// the process exit 99, and every CI rule that switches on the documented codes would misread it.
func normalize(c Code) Code {
	switch c {
	case OK, GateFail, Config, Infra, Host, Canceled:
		return c
	}
	return Host
}

// severity orders codes for aggregation. Deliberately not the numeric order: 0 is least severe
// yet sorts lowest, while 130 sorts highest and must win outright.
func severity(c Code) int {
	switch c {
	case OK:
		return 0
	case GateFail:
		return 1
	case Config:
		return 2
	case Infra:
		return 3
	case Host:
		return 4
	case Canceled:
		return 5
	}
	return 4
}

// Aggregator folds many per-command results into one process exit code.
//
// Every method is safe for concurrent use: sub-project 1B drives one reader goroutine per engine
// subprocess, and a timeout timer fires on yet another. Without the mutex, MarkTimeout racing
// AddSignalDeath could let a host-initiated kill be recorded as a host bug (spec §9).
type Aggregator struct {
	mu       sync.Mutex
	worst    Code
	timedOut bool
	canceled bool
}

// Add records a result. Every path except a host-initiated timeout kill goes through here.
func (a *Aggregator) Add(c Code) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.addLocked(c)
}

func (a *Aggregator) addLocked(c Code) {
	c = normalize(c)
	if severity(c) > severity(a.worst) {
		a.worst = c
	}
}

// AddSignalDeath records "the subprocess died from a signal". It is separate from Add(Host)
// because after MarkTimeout the host itself TERMs and KILLs the process group: that death is the
// expected consequence of the timeout, not a bug. A genuine host error reported through Add(Host)
// still wins, so a real defect is never hidden behind an unrelated slow chain.
func (a *Aggregator) AddSignalDeath() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.timedOut {
		return // this is the kill MarkTimeout already accounted for as Infra
	}
	a.addLocked(Host)
}

// MarkTimeout records that a command or stage hit its deadline: the chain stopped answering,
// which is an infrastructure condition (spec §11).
func (a *Aggregator) MarkTimeout() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.timedOut = true
	a.addLocked(Infra)
}

func (a *Aggregator) MarkCanceled() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.canceled = true
}

func (a *Aggregator) Result() Code {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.canceled {
		return Canceled // ^C outranks whatever the run had concluded so far
	}
	return normalize(a.worst)
}
