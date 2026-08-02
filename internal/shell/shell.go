// Package shell builds the interactive sandbox shell a student works in.
//
// A bare `bash` in the sandbox is a worse place to work than it needs to be:
// the task is in another window, and the only way to find out whether you have
// fixed anything is to leave. This package wires `task`, `hint`, `solution`,
// `verify` and `reset` into the shell itself, the way kubelings does, so the
// loop closes without leaving the box.
package shell

import (
	"fmt"
	"strings"

	"github.com/madhank93/devopslings/internal/course"
	"github.com/madhank93/devopslings/internal/md"
)

// Quote renders s as a single POSIX shell word.
//
// Go's %q is *Go* quoting, not shell quoting: it produces a double-quoted
// string, inside which the shell still expands $, backticks and history
// references. Titles and lesson names reach this file from course frontmatter
// and directory names, so a title containing $(…) would execute when the
// student opened a shell. Single quotes are literal in POSIX sh; the only
// character needing care is the single quote itself, which is closed, escaped,
// and reopened.
func Quote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// heredoc wraps body in a quoted heredoc, which passes it through untouched —
// no expansion, no quoting rules to get wrong. The terminator is unusual enough
// that lesson prose will not contain it.
func heredoc(varName, body string) string {
	return fmt.Sprintf("%s=$(cat <<'DEVOPSLINGS_EOF'\n%s\nDEVOPSLINGS_EOF\n)\n", varName, body)
}

// Config is what the rcfile needs to know that the lesson itself does not.
type Config struct {
	// Root is the repository checkout, and the working directory for a
	// host-side lesson.
	Root string

	// Binary is the absolute path to the devopslings binary, used by `verify`
	// and `reset` on host shells. Empty falls back to the name on PATH.
	Binary string

	// InContainer reports whether this shell runs inside the sandbox rather
	// than on the host. It decides how `verify` works: a host shell can call
	// the binary (which records progress), while a shell inside a container
	// cannot reach it and runs the lesson's own check script instead.
	InContainer bool

	// Width is the column count to wrap prose to.
	Width int
}

// RC returns the body of the bash rcfile for a lesson.
func RC(l course.Lesson, cfg Config) string {
	if cfg.Width <= 0 {
		cfg.Width = 100
	}
	bin := cfg.Binary
	if bin == "" {
		bin = "devopslings"
	}

	task := l.Task
	if strings.TrimSpace(task) == "" {
		task = "_This lesson has no task text._"
	}
	hint := l.Hint
	if strings.TrimSpace(hint) == "" {
		hint = "_This lesson has no hints._"
	}
	sol := l.Solution
	if strings.TrimSpace(sol) == "" {
		sol = "_This lesson has no written solution._"
	}

	var b strings.Builder
	b.WriteString("source ~/.bashrc 2>/dev/null || true\n")

	// Prose is pre-rendered on the host: glamour lives in the binary, and the
	// container has no idea what markdown is.
	b.WriteString(heredoc("DEVOPSLINGS_TASK", md.Render(task, cfg.Width)))
	b.WriteString(heredoc("DEVOPSLINGS_HINT", md.Render(hint, cfg.Width)))
	b.WriteString(heredoc("DEVOPSLINGS_SOLUTION", md.Render(sol, cfg.Width)))

	fmt.Fprintf(&b, "DEVOPSLINGS_LESSON=%s\n", Quote(l.Name))
	fmt.Fprintf(&b, "DEVOPSLINGS_ROOT=%s\n", Quote(cfg.Root))
	fmt.Fprintf(&b, "DEVOPSLINGS_BIN=%s\n", Quote(bin))

	b.WriteString(`
task()     { printf '%s\n' "$DEVOPSLINGS_TASK"; }
hint()     { printf '%s\n' "$DEVOPSLINGS_HINT"; }
solution() { printf '%s\n' "$DEVOPSLINGS_SOLUTION"; }
`)

	if cfg.InContainer {
		// The check runs in this same container, so running it here is exactly
		// what the grader does — but nothing records the result, because the
		// thing that writes progress is on the other side of the container
		// boundary. Say so rather than letting a student think they are done.
		b.WriteString(heredoc("DEVOPSLINGS_VERIFY", l.Tasks[course.TaskVerify].Run))
		b.WriteString(`
verify() {
  ( set -euo pipefail; eval "$DEVOPSLINGS_VERIFY" )
  local rc=$?
  printf '\n\e[2mrun from inside the sandbox, so nothing was recorded — press \e[0m\e[36mv\e[0m\e[2m in the TUI to log it.\e[0m\n'
  return $rc
}
reset() { printf 'reset runs on the host: exit, then press \e[36mr\e[0m in the TUI.\n'; }
`)
	} else {
		b.WriteString(`
verify() { ( cd "$DEVOPSLINGS_ROOT" && "$DEVOPSLINGS_BIN" verify "$DEVOPSLINGS_LESSON" ); }
reset()  { ( cd "$DEVOPSLINGS_ROOT" && "$DEVOPSLINGS_BIN" reset  "$DEVOPSLINGS_LESSON" ); }
`)
	}

	// A prompt that says which lesson you are in. Opening three shells for
	// three lessons and losing track of which is which is a real way to spend
	// twenty minutes debugging the wrong box.
	fmt.Fprintf(&b, "\nPS1='\\[\\e[36m\\]devopslings\\[\\e[0m\\]:%s \\w$ '\n", l.Name)

	b.WriteString(`
bind 'set completion-ignore-case on'   2>/dev/null || true
bind 'set show-all-if-ambiguous on'    2>/dev/null || true
bind '"\e[A": history-search-backward' 2>/dev/null || true
bind '"\e[B": history-search-forward'  2>/dev/null || true

clear
`)
	fmt.Fprintf(&b, "printf '\\e[1;36m%%s\\e[0m\\n\\n' %s\n", Quote(l.Title))
	b.WriteString("task\n")
	b.WriteString(`printf '\n\e[2mcommands:\e[0m \e[36mtask\e[0m · \e[36mhint\e[0m · \e[36mverify\e[0m · \e[36msolution\e[0m · \e[36mreset\e[0m · \e[36mexit\e[0m\n'
`)
	return b.String()
}
