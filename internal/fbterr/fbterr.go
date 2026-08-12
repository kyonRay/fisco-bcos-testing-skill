package fbterr

import (
	"errors"
	"fmt"
)

type Class int

const (
	ClassConfig Class = iota
	ClassInfra
	ClassHost
)

func (c Class) String() string {
	switch c {
	case ClassConfig:
		return "config"
	case ClassInfra:
		return "infra"
	case ClassHost:
		return "host"
	}
	return "unknown"
}

type classified struct {
	class Class
	err   error
}

func (e *classified) Error() string { return e.err.Error() }
func (e *classified) Unwrap() error { return e.err }

func Configf(format string, a ...interface{}) error {
	return &classified{ClassConfig, fmt.Errorf(format, a...)}
}
func Infraf(format string, a ...interface{}) error {
	return &classified{ClassInfra, fmt.Errorf(format, a...)}
}
func Hostf(format string, a ...interface{}) error {
	return &classified{ClassHost, fmt.Errorf(format, a...)}
}

func Wrap(err error, c Class) error {
	if err == nil {
		return nil
	}
	return &classified{c, err}
}

func ClassOf(err error) (Class, bool) {
	var last *classified
	for e := err; e != nil; e = errors.Unwrap(e) {
		if c, ok := e.(*classified); ok {
			last = c
		}
	}
	if last == nil {
		return 0, false
	}
	return last.class, true
}
