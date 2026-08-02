package runner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/madhank93/devopslings/internal/course"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "courses", "devopslings")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find repo root")
		}
		dir = parent
	}
}

func TestProject(t *testing.T) {
	if got := Project("linux-box"); got != "devopslings-linux-box" {
		t.Errorf("Project = %q", got)
	}
}

func TestFirstReason(t *testing.T) {
	cases := []struct{ in, want string }{
		{"not yet: disk is full", "disk is full"},
		{"some output\nNOT YET: still broken\nmore", "still broken"},
		{"  not yet:   padded  ", "padded"},
		{"PASS — all good", ""},
		{"", ""},
		// Only the first is reported: the earliest unmet condition is the one
		// the student should act on.
		{"not yet: first\nnot yet: second", "first"},
	}
	for _, c := range cases {
		if got := firstReason(c.in); got != c.want {
			t.Errorf("firstReason(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestTail(t *testing.T) {
	in := "a\nb\nc\nd\ne"
	if got := tail(in, 2); got != "d\ne" {
		t.Errorf("tail = %q", got)
	}
	if got := tail(in, 99); got != in {
		t.Errorf("tail with n > lines = %q", got)
	}
}

func TestExecRejectsUnsafeNames(t *testing.T) {
	r := New(repoRoot(t))
	ctx := context.Background()
	for _, bad := range []string{"../etc", "a/b", "-flag", ""} {
		if _, err := r.Exec(ctx, bad, "box", "true", ".", time.Second); err == nil {
			t.Errorf("Exec accepted stack %q", bad)
		}
		if _, err := r.Exec(ctx, "linux-box", bad, "true", ".", time.Second); err == nil {
			t.Errorf("Exec accepted service %q", bad)
		}
	}
}

func TestWorkDirIsScratchForStacklessLessons(t *testing.T) {
	root := repoRoot(t)
	r := New(root)
	stackless := course.Lesson{Name: "demo", Sandbox: course.Sandbox{Stack: NoStack, Service: HostService}}
	if got, want := r.workDir(stackless), filepath.Join(root, "scratch", "demo"); got != want {
		t.Errorf("workDir = %q, want %q", got, want)
	}
	stacked := course.Lesson{Name: "demo", Sandbox: course.Sandbox{Stack: "linux-box", Service: "box"}}
	if got, want := r.workDir(stacked), filepath.Join(root, "sandboxes", "linux-box"); got != want {
		t.Errorf("workDir = %q, want %q", got, want)
	}
}

// TestLessonContract is the real one: it puts every lesson through the full
// broken -> solved cycle against live Docker.
//
// It is slow (minutes) and needs a working daemon, so it is gated behind
// -short. CI runs it; `go test ./...` on a laptop skips it.
func TestLessonContract(t *testing.T) {
	if testing.Short() {
		t.Skip("needs docker; run without -short")
	}
	root := repoRoot(t)
	mods, err := course.Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	r := New(root)

	only := os.Getenv("DEVOPSLINGS_CONTRACT_LESSON")

	// Lessons that share a sandbox must not run concurrently: Contract tears the
	// stack down before it starts, so two lessons on linux-box would destroy
	// each other's scenario and fail in ways that look like flaky checks.
	// Different stacks are independent and do run in parallel.
	locks := map[string]*sync.Mutex{}
	var locksMu sync.Mutex
	lockFor := func(stack string) *sync.Mutex {
		locksMu.Lock()
		defer locksMu.Unlock()
		if locks[stack] == nil {
			locks[stack] = &sync.Mutex{}
		}
		return locks[stack]
	}

	for _, l := range course.All(mods) {
		if only != "" && l.Name != only {
			continue
		}
		t.Run(l.Name, func(t *testing.T) {
			// Timing-sensitive lessons measure wall-clock latency, so they get
			// the machine to themselves rather than competing for it.
			if !l.TimingSensitive {
				t.Parallel()
			}
			mu := lockFor(l.Sandbox.Stack)
			mu.Lock()
			defer mu.Unlock()

			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
			defer cancel()

			res := r.Contract(ctx, l)
			t.Log(strings.Join(res.Stages, " → "))
			if res.Failed() {
				t.Fatalf("%s violates the lesson contract: %v", l.Name, res.Err)
			}
		})
	}
}

// TestExecStreamsOutput covers the TUI's path through the runner: Out sees the
// lines as they are produced, and Result.Output still carries all of them.
//
// It uses the stackless/host combination, so it needs no docker daemon.
func TestExecStreamsOutput(t *testing.T) {
	var mu sync.Mutex
	var got []string
	r := &Runner{Root: repoRoot(t), Out: func(line string) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, line)
	}}

	script := "printf 'one\\ntwo\\n'; printf 'no-trailing-newline'"
	res, err := r.Exec(context.Background(), NoStack, HostService, script, t.TempDir(), 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !res.OK {
		t.Fatalf("script failed: %s", res.Output)
	}

	mu.Lock()
	defer mu.Unlock()
	want := []string{"one", "two", "no-trailing-newline"}
	if len(got) != len(want) {
		t.Fatalf("streamed %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d = %q, want %q", i, got[i], want[i])
		}
	}
	if !strings.Contains(res.Output, "one\ntwo\n") {
		t.Errorf("Result.Output lost content when streaming: %q", res.Output)
	}
}

// TestExecWithoutSinkIsUnchanged: the CLI leaves Out nil and must keep getting
// the whole output in one piece.
func TestExecWithoutSinkIsUnchanged(t *testing.T) {
	r := New(repoRoot(t))
	res, err := r.Exec(context.Background(), NoStack, HostService, "echo hello", t.TempDir(), 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !res.OK || strings.TrimSpace(res.Output) != "hello" {
		t.Errorf("Exec = %q, ok=%v", res.Output, res.OK)
	}
}

// TestShellCmdRCHostWritesAnRcfile covers the host half of the shell wiring:
// the rcfile is written somewhere bash can read it, and bash is told to use it.
// The container half needs a live sandbox and is covered by the contract run.
func TestShellCmdRCHostWritesAnRcfile(t *testing.T) {
	r := New(repoRoot(t))
	l := course.Lesson{Name: "demo", Sandbox: course.Sandbox{Stack: NoStack, Service: HostService}}

	c, cleanup, err := r.ShellCmdRC(l, "task() { echo hi; }\n")
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()

	if len(c.Args) < 3 || c.Args[1] != "--rcfile" {
		t.Fatalf("shell args = %v, want bash --rcfile <path> -i", c.Args)
	}
	body, err := os.ReadFile(c.Args[2])
	if err != nil {
		t.Fatalf("rcfile is not readable: %v", err)
	}
	if !strings.Contains(string(body), "task()") {
		t.Errorf("rcfile does not carry the helpers: %q", body)
	}

	// Cleanup has to actually remove it: one temp dir leaked per shell opened,
	// for the life of the machine, is the kind of thing nobody notices.
	cleanup()
	if _, err := os.Stat(c.Args[2]); err == nil {
		t.Error("cleanup left the rcfile behind")
	}
}

// TestShellCmdRCEmptyFallsBackToAPlainShell keeps `shell` working for a caller
// that has no prose to inject.
func TestShellCmdRCEmptyFallsBackToAPlainShell(t *testing.T) {
	r := New(repoRoot(t))
	l := course.Lesson{Name: "demo", Sandbox: course.Sandbox{Stack: NoStack, Service: HostService}}
	c, _, err := r.ShellCmdRC(l, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Args) != 1 || !strings.HasSuffix(c.Args[0], "bash") {
		t.Errorf("args = %v, want a plain bash", c.Args)
	}
}
