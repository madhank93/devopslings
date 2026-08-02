// Command devopslings runs the local DevOps scenario course.
//
// Subcommands are the headless surface: `doctor` checks the host, `list` shows
// progress, and start/verify/reset/down drive one lesson. The TUI sits on the
// same runner they do — running it with no arguments is the intended way in,
// and every key it binds has a subcommand equivalent for scripts and CI.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/madhank93/devopslings/internal/course"
	"github.com/madhank93/devopslings/internal/md"
	"github.com/madhank93/devopslings/internal/preflight"
	"github.com/madhank93/devopslings/internal/progress"
	"github.com/madhank93/devopslings/internal/runner"
	"github.com/madhank93/devopslings/internal/shell"
	"github.com/madhank93/devopslings/internal/ui"
)

const usage = `devopslings — break things locally, on purpose

usage:
  devopslings                     open the TUI
  devopslings doctor              check this host can run the sandboxes
  devopslings list                list modules, lessons and progress
  devopslings show <lesson>       print a lesson's task text
  devopslings start <lesson>      bring the sandbox up and break it
  devopslings verify <lesson>     grade your work
  devopslings reset <lesson>      tear down and start the lesson over
  devopslings shell <lesson>      open a shell in the lesson's sandbox
  devopslings down <lesson>       stop the lesson's sandbox
  devopslings tui                 open the TUI explicitly
`

func main() {
	// Ctrl-C should stop the work in flight, not orphan a half-built sandbox.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root, err := repoRoot()
	if err != nil {
		fatal(err)
	}

	// No arguments means the TUI. A student who cloned the repo and typed the
	// binary's name wants the course, not a usage message.
	cmd, args := "tui", []string{}
	if len(os.Args) > 1 {
		cmd, args = os.Args[1], os.Args[2:]
	}

	switch cmd {
	case "tui":
		if err := ui.Run(root); err != nil {
			fatal(err)
		}
	case "doctor":
		os.Exit(doctor(ctx))
	case "list":
		os.Exit(list(root))
	case "show", "start", "verify", "reset", "down", "shell":
		if len(args) != 1 {
			fmt.Fprintf(os.Stderr, "%s needs exactly one lesson name\n", cmd)
			os.Exit(2)
		}
		os.Exit(lessonCmd(ctx, root, cmd, args[0]))
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
}

// repoRoot walks up from the working directory looking for courses/devopslings,
// so the command works from anywhere inside the repo.
func repoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "courses", "devopslings")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside a devopslings checkout (no courses/devopslings above %s)", dir)
		}
		dir = parent
	}
}

func doctor(ctx context.Context) int {
	rep := preflight.Run(ctx)
	for _, c := range rep.Checks {
		glyph := map[preflight.Severity]string{
			preflight.OK: "✓", preflight.Warn: "!", preflight.Fail: "✗",
		}[c.Severity]
		fmt.Printf("%s %-26s %s\n", glyph, c.Name, c.Detail)
		if c.Fix != "" {
			fmt.Printf("    → %s\n", c.Fix)
		}
	}
	if rep.Blocked() {
		fmt.Println("\nsomething above must be fixed before any lesson will run.")
		return 1
	}
	fmt.Println("\nready.")
	return 0
}

func list(root string) int {
	mods, err := course.Discover(root)
	if err != nil {
		fatal(err)
	}
	done := progress.Load(root)
	for _, m := range mods {
		names := make([]string, 0, len(m.Lessons))
		for _, l := range m.Lessons {
			names = append(names, l.Name)
		}
		solved, _ := progress.Counts(done, names)
		fmt.Printf("\n%s — %s  (%d/%d)\n", m.Name, m.Title, solved, len(m.Lessons))
		for _, l := range m.Lessons {
			tags := []string{l.Type}
			if l.InjectsFault {
				tags = append(tags, "fault")
			}
			if l.TimingSensitive {
				tags = append(tags, "timed")
			}
			fmt.Printf("  %s %-24s %-38s [%s]\n",
				progress.Get(done, l.Name).Marker(), l.Name, truncate(l.Title, 38),
				strings.Join(tags, ","))
		}
	}
	fmt.Println()
	return 0
}

func lessonCmd(ctx context.Context, root, cmd, name string) int {
	mods, err := course.Discover(root)
	if err != nil {
		fatal(err)
	}
	l, ok := course.Find(mods, name)
	if !ok {
		fmt.Fprintf(os.Stderr, "no lesson named %q — try `devopslings list`\n", name)
		return 2
	}

	if cmd == "show" {
		fmt.Printf("%s\n\n%s\n", l.Title, l.Task)
		return 0
	}

	r := runner.New(root)

	switch cmd {
	case "start":
		fmt.Printf("starting %s (sandbox: %s)…\n", l.Name, l.Sandbox.Stack)
		res, err := r.Start(ctx, l)
		if err != nil {
			fatal(err)
		}
		if !res.OK {
			fmt.Print(res.Output)
			fmt.Fprintln(os.Stderr, "\nthe scenario failed to set up — this is a harness problem, not your answer.")
			return 1
		}
		_ = progress.Set(root, l.Name, progress.Started)
		fmt.Print(res.Output)
		if l.InjectsFault {
			fmt.Println("\nnote: this lesson injects a fault at verify time. You are being graded on surviving it, not on end state.")
		}
		fmt.Printf("\nready. `devopslings shell %s` to get in, `devopslings verify %s` when you're done.\n", l.Name, l.Name)
		return 0

	case "verify":
		res, err := r.Verify(ctx, l)
		if err != nil {
			fatal(err)
		}
		fmt.Print(res.Output)
		if !res.OK {
			return 1
		}
		_ = progress.Set(root, l.Name, progress.Solved)
		return 0

	case "reset":
		fmt.Printf("resetting %s…\n", l.Name)
		res, err := r.Reset(ctx, l)
		if err != nil {
			fatal(err)
		}
		fmt.Print(res.Output)
		if !res.OK {
			return 1
		}
		_ = progress.Set(root, l.Name, progress.Started)
		return 0

	case "down":
		res, err := r.Down(ctx, l.Sandbox.Stack)
		if err != nil {
			fatal(err)
		}
		fmt.Print(res.Output)
		if !res.OK {
			return 1
		}
		return 0

	case "shell":
		return openShell(root, l)
	}
	return 0
}

// openShell hands the terminal to the student inside the lesson's sandbox, with
// task/hint/verify/solution wired in — the same shell the TUI opens.
func openShell(root string, l course.Lesson) int {
	r := runner.New(root)
	bin, err := os.Executable()
	if err != nil {
		bin = ""
	}
	rc := shell.RC(l, shell.Config{
		Root:        root,
		Binary:      bin,
		InContainer: l.Sandbox.Service != runner.HostService,
		Width:       md.TerminalWidth(),
	})
	c, cleanup, err := r.ShellCmdRC(l, rc)
	if err != nil {
		fatal(err)
	}
	defer cleanup()
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		// A non-zero exit here is usually the student's last command failing or
		// them pressing Ctrl-D on a failed command. Not worth an error banner.
		return 0
	}
	return 0
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
