package ui

import (
	_ "embed"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/madhank93/devopslings/internal/course"
	"github.com/madhank93/devopslings/internal/md"
	"github.com/madhank93/devopslings/internal/preflight"
	prog "github.com/madhank93/devopslings/internal/progress"
)

// listWidth is the fixed width of the lesson column, borders included. Lesson
// names are the longest thing in it and they are bounded in practice.
const listWidth = 34

// Colours are adaptive: half the terminals in the world are light, and a
// palette picked only against a dark background turns into low-contrast mush on
// the other half.
var (
	cBlue  = lipgloss.AdaptiveColor{Light: "#0550ae", Dark: "#79c0ff"}
	cGreen = lipgloss.AdaptiveColor{Light: "#1a7f37", Dark: "#3fb950"}
	cAmber = lipgloss.AdaptiveColor{Light: "#9a6700", Dark: "#d29922"}
	cRed   = lipgloss.AdaptiveColor{Light: "#cf222e", Dark: "#f85149"}
	cTeal  = lipgloss.AdaptiveColor{Light: "#0e7490", Dark: "#39c5cf"}
	cDim   = lipgloss.AdaptiveColor{Light: "#6e7781", Dark: "#8b949e"}
)

var (
	titleStyle  = lipgloss.NewStyle().Bold(true)
	moduleStyle = lipgloss.NewStyle().Bold(true).Foreground(cBlue)
	dimStyle    = lipgloss.NewStyle().Foreground(cDim)
	keyStyle    = lipgloss.NewStyle().Bold(true).Foreground(cTeal)
	okStyle     = lipgloss.NewStyle().Bold(true).Foreground(cGreen)
	warnStyle   = lipgloss.NewStyle().Bold(true).Foreground(cAmber)
	failStyle   = lipgloss.NewStyle().Bold(true).Foreground(cRed)
	// Reverse rather than a fixed background: it inverts whatever the terminal
	// already uses, so the cursor bar is readable on any theme.
	cursorStyle  = lipgloss.NewStyle().Bold(true).Reverse(true)
	solvedStyle  = lipgloss.NewStyle().Foreground(cGreen)
	startedStyle = lipgloss.NewStyle().Foreground(cAmber)
	noneStyle    = lipgloss.NewStyle().Foreground(cDim)
	paneOn       = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cTeal)
	paneOff      = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cDim)
)

// helpText is the `?` pane. It lives in a file rather than a string literal
// because it is markdown full of backticks, and a raw Go string cannot contain
// one.
//
//go:embed help.md
var helpText string

// geometry is the single source of pane sizes. layout() sizes the viewports
// from it and View() draws the boxes from it; when the two disagreed by two
// lines, every pane rendered its content taller than the frame around it.
//
// The View is header + banner lines + panes + footer, so the panes get what is
// left. A box costs two rows of border and one of title, which is where the -4
// and the -1s come from.
func (m *model) geometry() (right, body, detailBox, outBox int) {
	body = max(m.h-m.chromeHeight(), 8)
	// One column of slack. Several glyphs in the list — ◐, ✓, box drawing — are
	// East Asian Ambiguous width: a terminal configured to draw them double
	// makes a row that fits by lipgloss's count one cell too wide, which wraps
	// the whole layout and scrolls the header off the top. Never fill the last
	// column.
	right = max(m.w-listWidth-5, 20)
	detailBox = (body - 4) * 3 / 5
	outBox = body - 4 - detailBox
	return
}

// chromeHeight is every row View() spends outside the panes.
func (m *model) chromeHeight() int {
	return 1 /*header*/ + len(m.issues) + 2 /*footer: keys + status*/
}

// listTop is the terminal row the first list entry is drawn on. Mouse hit
// testing reads it, so it must track View().
func (m *model) listTop() int {
	return 1 /*header*/ + len(m.issues) + 1 /*pane border*/ + 1 /*pane title*/
}

// listHeight is how many rows of lessons fit.
func (m *model) listHeight() int {
	_, body, _, _ := m.geometry()
	return max(body-3, 1)
}

// detailBottom is the first terminal row below the detail pane, used to decide
// which pane the scroll wheel is over.
func (m *model) detailBottom() int {
	_, _, detailBox, _ := m.geometry()
	return m.listTop() - 1 + detailBox + 2
}

func (m *model) layout() {
	right, _, detailBox, outBox := m.geometry()
	m.detail.Width, m.detail.Height = right, max(detailBox-1, 3)
	m.out.Width, m.out.Height = right, max(outBox-1, 3)
	// The help pop-up is three quarters of the frame, less its border and
	// padding, and never taller than the terminal.
	m.helpVP.Width = max(min(m.w*3/4-6, 72), 24)
	m.helpVP.Height = max(min(m.h-10, 24), 5)
	m.helpVP.SetContent(md.Render(helpText, m.helpVP.Width))
	m.mdCache = nil // renders are width-keyed; a resize invalidates them
	m.refreshDetail()
	m.out.SetContent(strings.Join(m.lines, "\n"))
	m.out.GotoBottom()
	m.clampOff()
}

func markerStyle(s prog.State) lipgloss.Style {
	switch s {
	case prog.Solved:
		return solvedStyle
	case prog.Started:
		return startedStyle
	}
	return noneStyle
}

// box draws a pane. MaxWidth/MaxHeight are the important part: Width and
// Height are minimums in lipgloss, so a single content line wider than the pane
// silently widens the whole column, pushes the layout past the terminal, and
// costs a row of wrap — which is how the header scrolled off the top.
func (m *model) box(focused bool, title, content string, w, h int) string {
	style := paneOff
	if focused {
		style = paneOn
	}
	return style.Width(w).Height(h).MaxWidth(w + 2).MaxHeight(h + 2).
		Render(titleStyle.Render(title) + "\n" + content)
}

// elapsed formats a task's running time. Minutes and seconds, because the
// tasks worth timing are the ones that take minutes: an image pull with no
// clock on it is indistinguishable from a hang.
func elapsed(d time.Duration) string {
	s := int(d.Seconds())
	if s < 60 {
		return fmt.Sprintf("%ds", s)
	}
	return fmt.Sprintf("%dm%02ds", s/60, s%60)
}

// bar draws the course progress meter.
//
// Hand-rolled rather than bubbles/progress: that widget's gradient emits a
// truecolor escape per cell, and a terminal that does not follow every one of
// them miscounts the line — which wraps the header row and scrolls it off the
// top of the screen. Two runes and one style are predictable everywhere.
func bar(ratio float64, width int) string {
	if width < 1 {
		return ""
	}
	filled := int(ratio*float64(width) + 0.5)
	filled = max(min(filled, width), 0)
	return solvedStyle.Render(strings.Repeat("█", filled)) +
		noneStyle.Render(strings.Repeat("░", width-filled))
}

// header carries the course-wide facts: how far through you are, and what the
// current lesson costs to run.
func (m *model) header() string {
	all := course.All(m.mods)
	names := make([]string, 0, len(all))
	for _, l := range all {
		names = append(names, l.Name)
	}
	solved, _ := prog.Counts(m.done, names)
	ratio := 0.0
	if len(names) > 0 {
		ratio = float64(solved) / float64(len(names))
	}

	l := m.current()
	sandbox := l.Sandbox.Stack
	if l.Sandbox.Service != "" {
		sandbox += "/" + l.Sandbox.Service
	}
	state := dimStyle.Render("idle")
	if m.running != "" {
		state = startedStyle.Render(m.spin.View()+" "+m.running) +
			dimStyle.Render(" "+elapsed(time.Since(m.started)))
	}

	// Narrow terminals drop the decoration rather than wrapping: a header that
	// wraps costs a row, and every row it costs pushes the frame down until the
	// top of the screen scrolls away.
	h := titleStyle.Render("devopslings") + " "
	if m.w >= 70 {
		h += bar(ratio, max(min(m.w/4, 30), 10))
	}
	h += dimStyle.Render(fmt.Sprintf(" %d/%d (%.0f%%)", solved, len(names), ratio*100)) +
		dimStyle.Render("  ·  ") + state
	if m.w >= 100 {
		h += dimStyle.Render(fmt.Sprintf("  ·  sandbox %s", sandbox))
	}
	return clip(h, m.w-1)
}

// banner surfaces preflight problems. A student whose docker is not running
// should learn it here rather than from a failed `start` two minutes later.
// clip truncates a line to n cells without cutting an escape sequence in half.
func clip(s string, n int) string {
	if n < 1 {
		return ""
	}
	return lipgloss.NewStyle().MaxWidth(n).Render(s)
}

func (m *model) banner() string {
	if len(m.issues) == 0 {
		return ""
	}
	var lines []string
	for _, c := range m.issues {
		style := warnStyle
		glyph := "⚠"
		if c.Severity == preflight.Fail {
			style, glyph = failStyle, "✗"
		}
		line := style.Render(glyph+" "+c.Name) + dimStyle.Render(" — "+c.Detail)
		if c.Fix != "" {
			line += dimStyle.Render(" → " + c.Fix)
		}
		lines = append(lines, clip(line, m.w-1))
	}
	return strings.Join(lines, "\n")
}

// listView renders the lesson column, with overflow arrows so it is obvious
// there is more list above or below.
func (m *model) listView() string {
	h := m.listHeight()
	inner := listWidth - 4
	var lines []string
	for i := m.off; i < len(m.rows) && len(lines) < h; i++ {
		r := m.rows[i]
		if r.header != "" {
			lines = append(lines, moduleStyle.Render(truncate(r.header, inner)))
			continue
		}
		state := prog.Get(m.done, r.lesson.Name)
		marker := markerStyle(state).Render(state.Marker())
		name := truncate(r.lesson.Name, inner-3)
		if len(m.sel) > 0 && m.sel[m.cur] == i {
			lines = append(lines, cursorStyle.Render(padRight(" "+state.Marker()+" "+name, inner)))
			continue
		}
		lines = append(lines, " "+marker+" "+name)
	}
	for len(lines) < h {
		lines = append(lines, "")
	}
	if m.off > 0 && lipgloss.Width(lines[0]) <= inner-2 {
		lines[0] = padRight(lines[0], inner-2) + dimStyle.Render("↑")
	}
	if last := len(lines) - 1; m.off+h < len(m.rows) && lipgloss.Width(lines[last]) <= inner-2 {
		lines[last] = padRight(lines[last], inner-2) + dimStyle.Render("↓")
	}
	return strings.Join(lines, "\n")
}

func keybar(pairs ...[2]string) string {
	var parts []string
	for _, p := range pairs {
		parts = append(parts, keyStyle.Render(p[0])+" "+dimStyle.Render(p[1]))
	}
	return strings.Join(parts, dimStyle.Render(" · "))
}

// footer is two rows: the keys, then whatever the harness last had to say.
func (m *model) footer() string {
	if m.filtering {
		return clip(keyStyle.Render("/")+m.filter+cursorStyle.Render(" ")+
			dimStyle.Render(fmt.Sprintf("   %d match(es) · ", len(m.sel)))+
			keybar([2]string{"↑↓", "move"}, [2]string{"↵", "keep"}, [2]string{"esc", "clear"}), m.w-1) + "\n"
	}

	// The keybar sheds keys as the terminal narrows, in reverse order of how
	// often they are needed. `?` survives every tier, because it is how you find
	// the ones that did not.
	all := [][2]string{
		{"↵", "play"}, {"i", "start"}, {"v", "verify"}, {"r", "reset"},
		{"t", "shell"}, {"h", "hint"}, {"s", "solution"}, {"d", "down"},
		{"/", "find"}, {"n", "next"}, {"?", "help"}, {"q", "quit"},
	}
	pairs := all
	for len(pairs) > 4 && lipgloss.Width(keybar(pairs...)) > m.w-1 {
		// Drop from the middle: the first few are the common actions and the
		// last two are help and quit.
		pairs = append(append([][2]string{}, pairs[:len(pairs)-3]...), pairs[len(pairs)-2:]...)
	}
	keys := keybar(pairs...)

	var status string
	switch {
	case m.confirmDown, m.confirmSolution, m.confirmShared, m.showHelp:
		// The pop-up is carrying the message; repeating it here would be noise.
		status = dimStyle.Render("")
	case m.running != "":
		status = startedStyle.Render(m.spin.View()+" "+m.running) +
			dimStyle.Render(" "+elapsed(time.Since(m.started))+" … ") +
			keybar([2]string{"esc", "cancel"})
	case m.mouseOff:
		status = warnStyle.Render("copy mode") +
			dimStyle.Render(" — mouse released; select with the terminal · ") +
			keyStyle.Render("m") + dimStyle.Render(" restores wheel scroll")
	case m.filter != "":
		status = dimStyle.Render("filter ") + keyStyle.Render("/"+m.filter) +
			dimStyle.Render(fmt.Sprintf("  %d of %d lessons · esc clears", len(m.sel), len(course.All(m.mods))))
	case strings.HasPrefix(m.status, "PASS"):
		status = okStyle.Render(m.status)
	case strings.HasPrefix(m.status, "not yet"):
		status = warnStyle.Render(m.status)
	default:
		status = m.status
	}
	return keys + "\n" + clip(status, m.w-1)
}

func (m *model) View() string {
	if !m.ready {
		return "starting…"
	}
	right, body, detailBox, outBox := m.geometry()

	// The pane title is where the eye already is while a task runs, so the
	// spinner goes there as well as in the header.
	outTitle := "output"
	if m.running != "" {
		outTitle = m.spin.View() + " " + m.running + " · " + elapsed(time.Since(m.started))
	}

	panes := lipgloss.JoinHorizontal(lipgloss.Top,
		m.box(m.focus == paneList, "lessons", m.listView(), listWidth, body-2),
		lipgloss.JoinVertical(lipgloss.Left,
			m.box(m.focus == paneDetail, m.view.label(), m.detail.View(), right, detailBox),
			m.box(m.focus == paneOutput, outTitle, m.out.View(), right, outBox),
		),
	)

	parts := []string{m.header()}
	if b := m.banner(); b != "" {
		parts = append(parts, b)
	}
	parts = append(parts, panes, m.footer())
	frame := strings.Join(parts, "\n")

	if box := m.popup(); box != "" {
		x, y := center(m.w, len(strings.Split(frame, "\n")), lipgloss.Width(box), lipgloss.Height(box))
		frame = overlay(frame, box, x, y)
	}
	return frame
}

// popup returns the pop-up to composite over the frame, or "" when there is
// none. Only one can be up at a time: they are all modal, and the key handler
// answers them in this same order.
func (m *model) popup() string {
	keysYN := keybar([2]string{"y", "yes"}, [2]string{"N", "no"})
	switch {
	case m.showHelp:
		return modal("help", m.helpVP.View(),
			keybar([2]string{"↑↓", "scroll"}, [2]string{"any key", "close"}), m.w*3/4)
	case m.confirmSolution:
		return modal("reveal the solution?",
			"The hint is usually enough, and the walkthrough is more useful after you have "+
				"been stuck than before.", keysYN, m.w/2)
	case m.confirmDown:
		return modal("stop "+m.current().Sandbox.Stack+"?",
			"Its volumes go with it, so the scenario is gone and the next start rebuilds "+
				"from scratch.", keysYN, m.w/2)
	case m.confirmShared:
		return modal("‘"+m.sharedWith+"’ is still in progress",
			"It runs on the same sandbox ("+m.sharedTarget.Sandbox.Stack+"), and starting this "+
				"lesson resets that sandbox — the work in ‘"+m.sharedWith+"’ goes with it.",
			keybar([2]string{"y", "start anyway"}, [2]string{"N", "cancel"}), m.w/2)
	}
	return ""
}

func truncate(s string, n int) string {
	if n < 1 {
		return ""
	}
	if lipgloss.Width(s) <= n {
		return s
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func padRight(s string, n int) string {
	if w := lipgloss.Width(s); w < n {
		return s + strings.Repeat(" ", n-w)
	}
	return s
}
