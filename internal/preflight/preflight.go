// Package preflight checks that the host can actually run the sandboxes before
// a student hits a confusing failure inside a lesson.
//
// The failure this exists to prevent is a student concluding they got the
// exercise wrong when in fact docker was not running, a port was taken, or the
// machine is too small for the stack. Every check here names the fix.
package preflight

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Severity distinguishes "nothing will work" from "some lessons will not work".
type Severity int

const (
	OK Severity = iota
	Warn
	Fail
)

func (s Severity) String() string {
	switch s {
	case OK:
		return "ok"
	case Warn:
		return "warn"
	default:
		return "fail"
	}
}

// Check is one host requirement and its outcome.
type Check struct {
	Name     string
	Severity Severity
	Detail   string
	Fix      string // what the student should do; empty when Severity is OK
}

// Report is the full preflight result.
type Report struct {
	Checks []Check
}

// Blocked reports whether any check failed outright.
func (r Report) Blocked() bool {
	for _, c := range r.Checks {
		if c.Severity == Fail {
			return true
		}
	}
	return false
}

// minMemoryBytes is the smallest docker allocation the v1 sandboxes fit in.
// ci-stack (forgejo + act_runner + harbor) is the constraint.
const minMemoryBytes = 4 << 30

// Run executes every check. Ports are the ones the v1 sandboxes bind.
func Run(ctx context.Context) Report {
	var r Report
	r.Checks = append(r.Checks, dockerPresent(ctx))
	if r.Blocked() {
		// Every later check talks to the daemon; running them now would just
		// produce a wall of consequential failures.
		return r
	}
	r.Checks = append(r.Checks, composeV2(ctx), memory(ctx))
	r.Checks = append(r.Checks, ports(3000, 5000, 8080, 8474, 9090)...)
	return r
}

func dockerPresent(ctx context.Context) Check {
	c := Check{Name: "docker daemon"}
	out, err := output(ctx, "docker", "info", "--format", "{{.ServerVersion}}")
	if err != nil {
		c.Severity = Fail
		c.Detail = "cannot reach the docker daemon"
		c.Fix = "start Docker Desktop, colima, or podman-machine, then re-run"
		return c
	}
	c.Detail = "server " + out
	return c
}

func composeV2(ctx context.Context) Check {
	c := Check{Name: "docker compose"}
	out, err := output(ctx, "docker", "compose", "version", "--short")
	if err != nil {
		c.Severity = Fail
		c.Detail = "docker compose v2 not available"
		c.Fix = "install the compose plugin — `docker-compose` v1 is not supported"
		return c
	}
	c.Detail = "v" + strings.TrimPrefix(out, "v")
	return c
}

func memory(ctx context.Context) Check {
	c := Check{Name: "memory available to docker"}
	out, err := output(ctx, "docker", "info", "--format", "{{.MemTotal}}")
	if err != nil {
		c.Severity = Warn
		c.Detail = "could not determine"
		return c
	}
	n, err := strconv.ParseInt(out, 10, 64)
	if err != nil {
		c.Severity = Warn
		c.Detail = "could not parse " + out
		return c
	}
	gib := float64(n) / (1 << 30)
	c.Detail = fmt.Sprintf("%.1f GiB", gib)
	if n < minMemoryBytes {
		c.Severity = Warn
		c.Fix = "raise the Docker memory limit to at least 4 GiB — ci-stack will not start below that"
	}
	return c
}

// ports checks that each port is free. A taken port is a Warn, not a Fail: it
// only breaks the sandboxes that bind it, and a student working through module
// 01 should not be stopped because something else on their machine owns 3000.
func ports(ns ...int) []Check {
	var out []Check
	for _, n := range ns {
		c := Check{Name: fmt.Sprintf("port %d free", n)}
		l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", n))
		if err != nil {
			c.Severity = Warn
			c.Detail = "in use"
			c.Fix = fmt.Sprintf("stop whatever owns :%d before starting a sandbox that binds it", n)
		} else {
			_ = l.Close()
			c.Detail = "free"
		}
		out = append(out, c)
	}
	return out
}

func output(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, name, args...).Output()
	return strings.TrimSpace(string(b)), err
}
