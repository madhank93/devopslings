// Package runner executes lesson tasks against a docker compose sandbox.
//
// kubelings delegates execution to a bash script wrapping kind and kubectl.
// devopslings has no such script: compose is a small enough surface that
// driving it directly from Go is simpler than driving it through shell, and it
// makes the lifecycle testable without a cluster.
//
// Every task script runs with `set -euo pipefail`, so a lesson author does not
// have to remember it and an unchecked command cannot silently pass a check.
package runner

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/madhank93/devopslings/internal/course"
)

// HostService is the reserved service name meaning "run this on the host, with
// the working directory set to the sandbox".
//
// Most task scripts run inside a container, because that is where the broken
// thing lives. Some cannot: killing a container, driving toxiproxy's admin API
// from outside the partition, or running k6 against the stack all have to
// happen from the host. Naming the host explicitly keeps that visible in the
// lesson frontmatter instead of hiding it behind a second mechanism.
const HostService = "host"

// NoStack is the reserved stack name for a lesson with nothing to bring up.
//
// Module 05 teaches Docker itself: the student writes Dockerfiles and compose
// files and builds them. Pre-starting a stack for that would be backwards — the
// thing under study is the build, not a running service. These lessons get a
// scratch working directory instead, and their tasks run on the host.
const NoStack = "none"

// DefaultTimeout bounds a task that does not set its own. Sandbox images pull
// on first run and CI stacks are slow to become healthy, so this is generous.
const DefaultTimeout = 240 * time.Second

// shellPrelude is prepended to every task script.
const shellPrelude = "set -euo pipefail\n"

// Runner executes tasks for lessons rooted at Root.
type Runner struct {
	Root string

	// Out, when set, receives task output one line at a time as it is produced.
	// Result.Output still carries the whole thing, so a caller that only wants
	// the end state leaves this nil — which is what the CLI does.
	//
	// The TUI sets it, because the tasks that matter most are the slow ones: a
	// first `up` pulls hundreds of megabytes and a CI verify waits on a build.
	// A pane that prints nothing for four minutes is indistinguishable from one
	// that has hung.
	//
	// It is called from the goroutine draining the command's output, so an
	// implementation that touches shared state has to say so itself.
	Out func(line string)
}

// New returns a Runner rooted at the repository root.
func New(root string) *Runner { return &Runner{Root: root} }

// Result is the outcome of one task.
type Result struct {
	Output string
	OK     bool

	// Reason is the first `not yet: ...` line the task printed, which is the
	// check telling the student specifically what is still wrong. Empty when
	// the task passed or failed without one.
	Reason string
}

// Project returns the compose project name for a stack. Stacks are isolated
// from each other and from anything else on the host's docker daemon.
func Project(stack string) string { return "devopslings-" + stack }

// composeFile returns the compose file for a stack, and whether it exists.
func (r *Runner) composeFile(stack string) (string, error) {
	if !course.ValidSandboxName(stack) {
		return "", fmt.Errorf("invalid sandbox stack name %q", stack)
	}
	p := filepath.Join(course.SandboxDir(r.Root, stack), "compose.yaml")
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("sandbox %q has no compose.yaml at %s", stack, p)
	}
	return p, nil
}

// compose builds a `docker compose` command for a stack.
func (r *Runner) compose(stack string, args ...string) (*exec.Cmd, error) {
	f, err := r.composeFile(stack)
	if err != nil {
		return nil, err
	}
	base := []string{"compose", "-f", f, "-p", Project(stack)}
	c := exec.Command("docker", append(base, args...)...)
	c.Dir = course.SandboxDir(r.Root, stack)
	return c, nil
}

// ScratchDir is where a stackless lesson's working files live. It is
// gitignored: a student's half-finished Dockerfile is not repository content.
func (r *Runner) ScratchDir(l course.Lesson) string {
	return filepath.Join(r.Root, "scratch", l.Name)
}

// workDir returns the directory a lesson's host-side tasks run in.
func (r *Runner) workDir(l course.Lesson) string {
	if l.Sandbox.Stack == NoStack {
		return r.ScratchDir(l)
	}
	return course.SandboxDir(r.Root, l.Sandbox.Stack)
}

// Up starts a stack and waits for its services to report healthy.
//
// --wait makes compose block on healthchecks rather than returning as soon as
// containers are created. Lessons depend on it: a verify that races a
// still-starting Postgres fails for a reason that has nothing to do with the
// student.
//
// --build costs a cache check on every start and buys the guarantee that the
// running box matches its Dockerfile. Without it, a sandbox edited to add a
// package keeps starting from the image built before the edit, and the lesson
// that needed the package fails with "command not found" on a machine where
// the Dockerfile plainly installs it.
func (r *Runner) Up(ctx context.Context, stack string) (Result, error) {
	if stack == NoStack {
		return Result{OK: true}, nil
	}
	c, err := r.compose(stack, "up", "-d", "--wait", "--build", "--remove-orphans")
	if err != nil {
		return Result{}, err
	}
	out, ok := run(ctx, c, 10*time.Minute, r.Out)
	return Result{Output: out, OK: ok}, nil
}

// Down stops a stack and removes its volumes, returning it to a clean slate.
func (r *Runner) Down(ctx context.Context, stack string) (Result, error) {
	if stack == NoStack {
		return Result{OK: true}, nil
	}
	c, err := r.compose(stack, "down", "-v", "--remove-orphans")
	if err != nil {
		return Result{}, err
	}
	out, ok := run(ctx, c, 5*time.Minute, r.Out)
	return Result{Output: out, OK: ok}, nil
}

// IsUp reports whether the stack has any running containers.
func (r *Runner) IsUp(ctx context.Context, stack string) bool {
	c, err := r.compose(stack, "ps", "-q", "--status", "running")
	if err != nil {
		return false
	}
	out, ok := run(ctx, c, 30*time.Second, nil) // probe, not a task: never streamed
	return ok && strings.TrimSpace(out) != ""
}

// Exec runs a script in a stack's service, or on the host when service is
// HostService. dir is the working directory for host-side scripts.
func (r *Runner) Exec(ctx context.Context, stack, service, script, dir string, timeout time.Duration) (Result, error) {
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	body := shellPrelude + script

	var c *exec.Cmd
	if service == HostService {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return Result{}, err
		}
		c = exec.Command("bash", "-c", body)
		c.Dir = dir
		c.Env = append(os.Environ(), "DEVOPSLINGS_ROOT="+r.Root)
		// A stackless lesson has no compose project to point at; one with a
		// stack gets the coordinates so its scripts don't have to recompute
		// them.
		if stack != NoStack {
			f, err := r.composeFile(stack)
			if err != nil {
				return Result{}, err
			}
			c.Env = append(c.Env,
				"COMPOSE_FILE="+f,
				"COMPOSE_PROJECT_NAME="+Project(stack),
			)
		}
	} else {
		if !course.ValidSandboxName(service) {
			return Result{}, fmt.Errorf("invalid sandbox service name %q", service)
		}
		var err error
		// -T disables TTY allocation: task output is captured, never interactive.
		c, err = r.compose(stack, "exec", "-T", service, "bash", "-c", body)
		if err != nil {
			return Result{}, err
		}
	}

	out, ok := run(ctx, c, timeout, r.Out)
	return Result{Output: out, OK: ok, Reason: firstReason(out)}, nil
}

// RunTask runs one named task of a lesson.
func (r *Runner) RunTask(ctx context.Context, l course.Lesson, name string) (Result, error) {
	t, ok := l.Tasks[name]
	if !ok {
		return Result{}, fmt.Errorf("lesson %q has no task %q", l.Name, name)
	}
	service := t.Service
	if service == "" {
		service = l.Sandbox.Service
	}
	if service == "" {
		return Result{}, fmt.Errorf("lesson %q task %q names no service", l.Name, name)
	}
	return r.Exec(ctx, l.Sandbox.Stack, service, t.Run, r.workDir(l),
		time.Duration(t.TimeoutSeconds)*time.Second)
}

// Start brings the sandbox up and runs the lesson's init task, leaving the
// scenario broken and ready for the student.
func (r *Runner) Start(ctx context.Context, l course.Lesson) (Result, error) {
	if res, err := r.Up(ctx, l.Sandbox.Stack); err != nil || !res.OK {
		if err != nil {
			return Result{}, err
		}
		return Result{Output: res.Output, OK: false}, nil
	}
	if _, ok := l.Tasks[course.TaskInit]; !ok {
		return Result{OK: true}, nil
	}
	return r.RunTask(ctx, l, course.TaskInit)
}

// Verify grades the lesson.
//
// When the lesson declares an inject_fault task it runs first, and a failure to
// inject is reported as an infrastructure error rather than a failed check —
// the student did not fail, the harness did, and saying otherwise would teach
// them to distrust the grader.
func (r *Runner) Verify(ctx context.Context, l course.Lesson) (Result, error) {
	if _, ok := l.Tasks[course.TaskFault]; ok {
		res, err := r.RunTask(ctx, l, course.TaskFault)
		if err != nil {
			return Result{}, err
		}
		if !res.OK {
			return Result{
				Output: res.Output,
				OK:     false,
				Reason: "fault injection failed — this is a harness problem, not your answer. Reset the scenario and retry.",
			}, nil
		}
	}
	return r.RunTask(ctx, l, course.TaskVerify)
}

// Reset tears the sandbox down and starts the lesson again from scratch.
func (r *Runner) Reset(ctx context.Context, l course.Lesson) (Result, error) {
	if _, err := r.Down(ctx, l.Sandbox.Stack); err != nil {
		return Result{}, err
	}
	return r.Start(ctx, l)
}

// ShellCmdRC returns an interactive shell into a lesson's sandbox with rc
// sourced as the bash startup file, plus a cleanup to call when it exits.
//
// The rcfile is what turns a bare prompt into a place to work: it defines
// task/hint/verify/solution. Getting it into a *container* is the awkward part,
// because there is nothing to bind-mount into a running one — so it travels as
// base64 on the command line and is written out inside.
//
// An empty rc gives a plain shell.
func (r *Runner) ShellCmdRC(l course.Lesson, rc string) (*exec.Cmd, func(), error) {
	noop := func() {}
	if rc == "" {
		c, err := r.ShellCmd(l)
		return c, noop, err
	}

	service := l.Sandbox.Service
	if service == HostService {
		dir, err := os.MkdirTemp("", "devopslings-shell")
		if err != nil {
			return nil, noop, err
		}
		// The rcfile carries nothing secret, but it is executed as the student,
		// so no other account on the machine gets to write it.
		if err := os.Chmod(dir, 0o700); err != nil {
			return nil, noop, err
		}
		path := filepath.Join(dir, "rc")
		if err := os.WriteFile(path, []byte(rc), 0o600); err != nil {
			return nil, noop, err
		}
		work := r.workDir(l)
		if err := os.MkdirAll(work, 0o755); err != nil {
			return nil, noop, err
		}
		c := exec.Command("bash", "--rcfile", path, "-i")
		c.Dir = work
		return c, func() { _ = os.RemoveAll(dir) }, nil
	}

	if !course.ValidSandboxName(service) {
		return nil, noop, fmt.Errorf("invalid sandbox service name %q", service)
	}
	// The rcfile goes in with `compose cp` rather than on the command line.
	// Passing it as an argument is simpler and works right up until the prose
	// grows: a rendered task plus hints is several kilobytes of ANSI, and the
	// container's exec rejects it with "argument list too long".
	dir, err := os.MkdirTemp("", "devopslings-shell")
	if err != nil {
		return nil, noop, err
	}
	cleanup := func() { _ = os.RemoveAll(dir) }
	local := filepath.Join(dir, "rc")
	if err := os.WriteFile(local, []byte(rc), 0o600); err != nil {
		cleanup()
		return nil, noop, err
	}
	cp, err := r.compose(l.Sandbox.Stack, "cp", local, service+":"+containerRC)
	if err != nil {
		cleanup()
		return nil, noop, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if out, ok := run(ctx, cp, 60*time.Second, nil); !ok {
		cleanup()
		return nil, noop, fmt.Errorf("could not copy the shell setup into %s: %s", service, tail(out, 3))
	}
	// The rcfile flag goes inside a `bash -c`, not on compose's own command
	// line: compose's flag parser swallows a bare --rcfile and silently starts
	// a plain shell, which looks exactly like the rcfile failing to load.
	c, err := r.compose(l.Sandbox.Stack, "exec", service,
		"bash", "-c", "exec bash --rcfile "+containerRC+" -i")
	if err != nil {
		cleanup()
		return nil, noop, err
	}
	return c, cleanup, nil
}

// containerRC is where the shell's rcfile lands inside a sandbox container.
//
// Not /tmp: `compose cp` writes into the container's filesystem layer, and
// linux-box runs real systemd, which mounts a tmpfs over /tmp at boot. The copy
// reports success and the file is invisible to every later exec, because it is
// underneath the mount.
const containerRC = "/etc/devopslings-rc"

// ShellCmd returns an interactive shell into a lesson's sandbox service, with
// the caller's stdio attached.
//
// This is the one path that does not capture output: the student is driving it,
// so it needs a TTY and must not be wrapped in the prelude or a timeout.
func (r *Runner) ShellCmd(l course.Lesson) (*exec.Cmd, error) {
	service := l.Sandbox.Service
	if service == HostService {
		dir := r.workDir(l)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
		c := exec.Command("bash")
		c.Dir = dir
		return c, nil
	}
	if !course.ValidSandboxName(service) {
		return nil, fmt.Errorf("invalid sandbox service name %q", service)
	}
	return r.compose(l.Sandbox.Stack, "exec", service, "bash", "-l")
}

// firstReason extracts the first `not yet: ...` line from task output.
func firstReason(out string) string {
	for line := range strings.SplitSeq(out, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(strings.ToLower(t), "not yet:") {
			return strings.TrimSpace(t[len("not yet:"):])
		}
	}
	return ""
}

// lineWriter calls sink once per complete line written through it, and holds a
// partial trailing line until the rest of it arrives.
//
// Docker writes progress in chunks that do not align to lines, so splitting on
// the write boundary would hand the caller fragments.
type lineWriter struct {
	sink    func(string)
	partial strings.Builder
}

func (w *lineWriter) Write(p []byte) (int, error) {
	for _, b := range p {
		if b == '\n' {
			w.sink(w.partial.String())
			w.partial.Reset()
			continue
		}
		w.partial.WriteByte(b)
	}
	return len(p), nil
}

// flush emits whatever is left when the command exits without a final newline.
func (w *lineWriter) flush() {
	if w.partial.Len() > 0 {
		w.sink(w.partial.String())
		w.partial.Reset()
	}
}

// run executes cmd with a timeout, returning combined output and success. When
// sink is non-nil it also receives each line as it appears.
//
// The command shells out to docker, which spawns its own children; killing the
// parent alone would orphan them. Each run gets its own process group so a
// timeout or cancellation stops the whole tree.
func run(ctx context.Context, c *exec.Cmd, timeout time.Duration, sink func(string)) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var buf strings.Builder

	// Stdout and Stderr must be the same value, not two writers wrapping the
	// same buffer: os/exec gives them one pipe and one goroutine when they are
	// equal, and two racing goroutines when they are not.
	var sw io.Writer = &buf
	if sink != nil {
		lw := &lineWriter{sink: sink}
		defer lw.flush()
		sw = io.MultiWriter(&buf, lw)
	}
	c.Stdout, c.Stderr = sw, sw

	if err := c.Start(); err != nil {
		return err.Error(), false
	}
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()

	select {
	case err := <-done:
		return buf.String(), err == nil
	case <-ctx.Done():
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		<-done
		return buf.String() + fmt.Sprintf("\n\n^ timed out after %s", timeout), false
	}
}
