package shell

import (
	"regexp"
	"strings"
	"testing"

	"github.com/madhank93/devopslings/internal/course"
)

func lesson() course.Lesson {
	return course.Lesson{
		Name:     "disk-full-triage",
		Title:    "The disk is full but du says it isn't",
		Task:     "## The situation\n\nThe disk is at 91%.",
		Hint:     "`df` counts blocks, `du` counts names.",
		Solution: "Stop the unit.",
		Sandbox:  course.Sandbox{Stack: "linux-box", Service: "box"},
		Tasks: map[string]course.Task{
			course.TaskVerify: {Run: "echo checking; exit 1"},
		},
	}
}

// TestQuoteIsShellSafe: titles and lesson names come from frontmatter and
// directory names, and they land in a file bash executes.
func TestQuoteIsShellSafe(t *testing.T) {
	cases := map[string]string{
		"plain":     `'plain'`,
		"it's":      `'it'\''s'`,
		"$(whoami)": `'$(whoami)'`,
		"`id`":      "'`id`'",
		"a\nb":      "'a\nb'",
	}
	for in, want := range cases {
		if got := Quote(in); got != want {
			t.Errorf("Quote(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestRCDefinesTheCommands is the whole point of the rcfile: a student in the
// sandbox can read the task and grade themselves without leaving it.
func TestRCDefinesTheCommands(t *testing.T) {
	rc := RC(lesson(), Config{Root: "/repo", Binary: "/repo/bin/devopslings", Width: 80})
	for _, fn := range []string{"task()", "hint()", "solution()", "verify()", "reset()"} {
		if !strings.Contains(rc, fn) {
			t.Errorf("rcfile does not define %s", fn)
		}
	}
	plain := stripANSI(rc)
	if !strings.Contains(plain, "The disk is at 91%") {
		t.Errorf("task prose is not in the rcfile:\n%s", plain)
	}
	if strings.Contains(plain, "## The situation") {
		t.Error("task prose reached the shell unrendered")
	}
	// It has to print the task on entry, or the student has to know to ask.
	if !strings.HasSuffix(strings.TrimSpace(lastLines(rc, 3)), `· \e[36mexit\e[0m\n'`) &&
		!strings.Contains(rc, "\ntask\n") {
		t.Error("the rcfile does not show the task when the shell opens")
	}
}

// TestHostShellCallsTheBinary: a host shell can reach the binary, so verify
// goes through the same path as `devopslings verify` and progress is recorded.
func TestHostShellCallsTheBinary(t *testing.T) {
	l := lesson()
	l.Sandbox.Service = "host"
	rc := RC(l, Config{Root: "/repo", Binary: "/repo/bin/devopslings"})
	if !strings.Contains(rc, `"$DEVOPSLINGS_BIN" verify "$DEVOPSLINGS_LESSON"`) {
		t.Error("host verify does not call the binary")
	}
	if strings.Contains(rc, "DEVOPSLINGS_VERIFY=") {
		t.Error("host shell embedded the check script instead of calling the binary")
	}
}

// TestContainerShellRunsTheCheckInline: inside a container the binary is
// unreachable, so verify runs the lesson's own check — and must say that
// nothing was recorded, or a student reads a pass as progress.
func TestContainerShellRunsTheCheckInline(t *testing.T) {
	rc := RC(lesson(), Config{Root: "/repo", Binary: "/repo/bin/devopslings", InContainer: true})
	if !strings.Contains(rc, "echo checking; exit 1") {
		t.Error("the check script is not embedded")
	}
	if !strings.Contains(rc, "nothing was recorded") {
		t.Error("inline verify does not say the result was not recorded")
	}
	if !strings.Contains(rc, "reset runs on the host") {
		t.Error("reset does not explain itself inside a container")
	}
}

// TestMissingProseStillDefinesTheCommands: a lesson with no hint must not
// produce a shell where `hint` is undefined.
func TestMissingProseStillDefinesTheCommands(t *testing.T) {
	l := lesson()
	l.Hint, l.Solution, l.Task = "", "", ""
	rc := RC(l, Config{Root: "/repo"})
	for _, fn := range []string{"task()", "hint()", "solution()"} {
		if !strings.Contains(rc, fn) {
			t.Errorf("rcfile does not define %s", fn)
		}
	}
	if !strings.Contains(rc, "no hints") {
		t.Error("hint does not explain that there are none")
	}
}

// stripANSI removes the styling glamour adds, so a test can look for the words.
var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
