package ui

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/madhank93/devopslings/internal/course"
	prog "github.com/madhank93/devopslings/internal/progress"
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

func newTestModel(t *testing.T) *model {
	t.Helper()
	m, err := newModel(repoRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	return m
}

func press(m *model, keys string) {
	for _, r := range keys {
		if r == '\n' {
			m.Update(tea.KeyMsg{Type: tea.KeyEnter})
			continue
		}
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
}

// TestSelectionStaysOnALesson guards the invariant every action depends on:
// current() must always be a real lesson, or `verify` grades a module heading.
func TestSelectionStaysOnALesson(t *testing.T) {
	m := newTestModel(t)
	for i := 0; i < len(m.rows)+5; i++ {
		m.moveSel(1)
		if m.current().Name == "" {
			t.Fatalf("current() has no lesson after %d moves down", i+1)
		}
	}
	for i := 0; i < len(m.rows)+5; i++ {
		m.moveSel(-1)
		if m.current().Name == "" {
			t.Fatalf("current() has no lesson after %d moves up", i+1)
		}
	}
}

// TestViewShowsLessonsAndProgress checks the frame renders real content: the
// list, the header's counter, and the keybar.
func TestViewShowsLessonsAndProgress(t *testing.T) {
	m := newTestModel(t)
	out := m.View()
	for _, want := range []string{"disk-full-triage", "devopslings", "play", "verify"} {
		if !strings.Contains(out, want) {
			t.Errorf("view is missing %q", want)
		}
	}
}

// TestTaskPaneRendersMarkdown: prose goes through glamour, so the raw `##` and
// backticks a lesson author writes must not reach the pane.
func TestTaskPaneRendersMarkdown(t *testing.T) {
	m := newTestModel(t)
	src := m.current().Task
	if !strings.Contains(src, "## ") {
		t.Skip("first lesson has no markdown heading to check")
	}
	rendered := m.md(m.current().Name+"|task", src, 60)
	if strings.Contains(rendered, "## ") {
		t.Errorf("heading markers survived the render:\n%s", rendered)
	}
	if rendered == src {
		t.Error("markdown was passed through unrendered")
	}
	// Second call must come from the cache rather than a second glamour run.
	if got := m.md(m.current().Name+"|task", src, 60); got != rendered {
		t.Error("cached render differs from the first")
	}
}

// TestSolutionNeedsConfirmation is the pedagogy as a test: the answer takes a
// deliberate y, and n leaves the pane where it was.
func TestSolutionNeedsConfirmation(t *testing.T) {
	m := newTestModel(t)
	if m.current().Solution == "" {
		t.Skip("first lesson has no solution")
	}
	press(m, "s")
	if !m.confirmSolution {
		t.Fatal("s did not ask for confirmation")
	}
	if m.view == viewSolution {
		t.Fatal("solution was revealed before confirming")
	}
	press(m, "n")
	if m.view == viewSolution || m.confirmSolution {
		t.Fatal("n revealed the solution")
	}
	press(m, "s")
	press(m, "y")
	if m.view != viewSolution {
		t.Fatal("y did not reveal the solution")
	}

	// Moving to another lesson must close it again, or one peek unhides every
	// later answer without the student choosing to.
	m.moveSel(1)
	if m.view != viewTask {
		t.Error("changing lesson left the solution open")
	}
}

// TestSharedSandboxGuard: ci-stack is shared by first-pipeline and
// leaked-secret, and init_scenario force-pushes over the repo. Starting one
// while the other is in progress destroys that work, so it must ask first.
func TestSharedSandboxGuard(t *testing.T) {
	m := newTestModel(t)

	var a, b course.Lesson
	for _, l := range course.All(m.mods) {
		if !l.HasTasks || l.Sandbox.Stack == "none" {
			continue
		}
		if a.Name == "" {
			a = l
			continue
		}
		if l.Sandbox.Stack == a.Sandbox.Stack {
			b = l
			break
		}
	}
	if b.Name == "" {
		t.Skip("no two lessons share a sandbox")
	}

	m.done = map[string]prog.State{a.Name: prog.Started}
	m.begin(b, false)
	if m.running != "" {
		t.Error("starting b ran immediately instead of asking about a")
	}
	if !m.confirmShared || m.sharedWith != a.Name {
		t.Fatalf("no guard raised: confirm=%v with=%q", m.confirmShared, m.sharedWith)
	}
	if !strings.Contains(stripANSI(m.popup()), a.Name) {
		t.Error("the pop-up does not name the lesson about to be destroyed")
	}
	if !strings.Contains(stripANSI(m.View()), a.Name) {
		t.Error("the pop-up is not composited into the view")
	}

	// A lesson with no other started lesson on its stack starts straight away.
	m.done = map[string]prog.State{}
	m.confirmShared = false
	if cmd := m.begin(b, false); cmd == nil {
		t.Error("begin refused to start with nothing else in progress")
	}
}

// TestDownAsksFirst: `down` removes the stack's volumes.
func TestDownAsksFirst(t *testing.T) {
	m := newTestModel(t)
	press(m, "d")
	if !m.confirmDown {
		t.Fatal("d did not ask for confirmation")
	}
	press(m, "n")
	if m.confirmDown {
		t.Error("n left the confirmation open")
	}
}

// TestFilterNarrowsAndKeepsHeaders: a filtered list must never show a module
// heading with no lessons under it.
func TestFilterNarrowsAndKeepsHeaders(t *testing.T) {
	m := newTestModel(t)
	all := len(m.sel)
	press(m, "/")
	if !m.filtering {
		t.Fatal("/ did not enter filter mode")
	}
	press(m, "leaked")
	if len(m.sel) == 0 || len(m.sel) >= all {
		t.Fatalf("filter matched %d of %d lessons", len(m.sel), all)
	}
	for i, r := range m.rows {
		if r.header == "" {
			continue
		}
		if i == len(m.rows)-1 || m.rows[i+1].header != "" {
			t.Errorf("module heading %q has no lessons under it", r.header)
		}
	}
	// Typing must not have run anything: "d" is `down` outside filter mode.
	if m.confirmDown || m.running != "" {
		t.Error("filter text leaked into the command keys")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if m.filter != "" || len(m.sel) != all {
		t.Error("esc did not clear the filter")
	}
}

// TestNextUnsolvedSkipsSolved keeps "where was I" from being a scrolling
// exercise on a course this long.
func TestNextUnsolvedSkipsSolved(t *testing.T) {
	m := newTestModel(t)
	if len(m.sel) < 2 {
		t.Skip("need at least two lessons")
	}
	m.done = map[string]prog.State{}
	for _, l := range course.All(m.mods) {
		m.done[l.Name] = prog.Solved
	}
	target := m.rows[m.sel[len(m.sel)-1]].lesson.Name
	delete(m.done, target)

	if !m.nextUnsolved() {
		t.Fatal("nextUnsolved found nothing with one lesson unsolved")
	}
	if got := m.current().Name; got != target {
		t.Errorf("landed on %q, want %q", got, target)
	}

	for _, l := range course.All(m.mods) {
		m.done[l.Name] = prog.Solved
	}
	if m.nextUnsolved() {
		t.Error("nextUnsolved moved with everything solved")
	}
}

// TestScrollKeysMoveTheFocusedPane: the list, the task and the output scroll
// independently, and tab is what says which.
func TestScrollKeysMoveTheFocusedPane(t *testing.T) {
	m := newTestModel(t)
	for i := 0; i < 200; i++ {
		m.appendLine("output line")
	}
	m.detail.SetContent(strings.Repeat("task line\n", 200))

	m.focus = paneDetail
	m.detail.GotoTop()
	before := m.detail.YOffset
	m.Update(tea.KeyMsg{Type: tea.KeyPgDown})
	if m.detail.YOffset <= before {
		t.Error("pgdn did not scroll the detail pane")
	}
	outBefore := m.out.YOffset

	m.focus = paneOutput
	m.Update(tea.KeyMsg{Type: tea.KeyPgUp})
	if m.out.YOffset >= outBefore {
		t.Error("pgup did not scroll the output pane when focused")
	}
	if m.current().Name == "" {
		t.Error("scrolling moved the lesson selection")
	}
}

// TestOutputScrollbackIsBounded: a `compose up` that pulls images emits tens of
// thousands of progress lines, and the pane must not grow without limit.
func TestOutputScrollbackIsBounded(t *testing.T) {
	m := newTestModel(t)
	for i := 0; i < maxOutputLines+500; i++ {
		m.appendLine("line")
	}
	if len(m.lines) != maxOutputLines {
		t.Errorf("scrollback holds %d lines, want %d", len(m.lines), maxOutputLines)
	}
}

// TestOneTaskAtATime: two compose commands against the same project race, and
// the interleaved output would be unreadable anyway.
func TestOneTaskAtATime(t *testing.T) {
	m := newTestModel(t)
	m.running = "start disk-full-triage"
	if cmd := m.run("verify", m.current()); cmd != nil {
		t.Error("a second task was started while one was running")
	}
	if !strings.Contains(m.status, "still running") {
		t.Errorf("status does not explain the refusal: %q", m.status)
	}
}

// TestHelpIsAPopupOverTheFrame: help must not replace the task pane, or you
// cannot read the keys and the thing you were doing at the same time.
func TestHelpIsAPopupOverTheFrame(t *testing.T) {
	m := newTestModel(t)
	press(m, "?")
	if !m.showHelp {
		t.Fatal("? did not open help")
	}
	view := stripANSI(m.View())
	if !strings.Contains(view, "help") {
		t.Error("help pop-up is not in the view")
	}
	if !strings.Contains(view, "disk-full-triage") {
		t.Error("the lesson list disappeared behind the pop-up")
	}
	// Any key closes it, and that key must not also fire its normal action.
	press(m, "d")
	if m.showHelp {
		t.Error("a keypress did not close help")
	}
	if m.confirmDown {
		t.Error("the key that closed help also ran its action")
	}
}

// TestHelpListsEveryBoundKey keeps `?` honest as the keymap changes.
func TestHelpListsEveryBoundKey(t *testing.T) {
	for _, k := range []string{"↵", "`i`", "`t`", "`v`", "`r`", "`d`", "`h`", "`s`", "`/`", "`n`", "`g`", "`m`", "`q`"} {
		if !strings.Contains(helpText, k) {
			t.Errorf("help does not document %s", k)
		}
	}
}

func TestTruncate(t *testing.T) {
	cases := []struct {
		in   string
		n    int
		want string
	}{
		{"short", 10, "short"},
		{"exactly-ten", 11, "exactly-ten"},
		{"a-very-long-lesson-name", 8, "a-very-…"},
		{"anything", 0, ""},
	}
	for _, c := range cases {
		if got := truncate(c.in, c.n); got != c.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
		}
	}
}

// TestFastTypingIsNotSwallowed: keys typed faster than the read loop arrive as
// one KeyRunes carrying several runes. Matching on msg.String() would compare
// against "/leaked" and hit no case, so a quick "/" + query did nothing at all.
func TestFastTypingIsNotSwallowed(t *testing.T) {
	m := newTestModel(t)
	all := len(m.sel)
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("/leaked")})
	if !m.filtering {
		t.Fatal("the burst's leading / did not open the filter")
	}
	if m.filter != "leaked" {
		t.Fatalf("filter = %q, want %q", m.filter, "leaked")
	}
	if len(m.sel) == 0 || len(m.sel) >= all {
		t.Errorf("filter matched %d of %d lessons", len(m.sel), all)
	}
}

// stripANSI removes styling so a test can look for the words.
var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }
