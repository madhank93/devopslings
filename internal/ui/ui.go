// Package ui is the terminal front end: a lesson list, the lesson's prose, and
// a pane that streams task output while a task runs.
//
// It drives the same runner the subcommands do and holds no lesson knowledge of
// its own. Anything the TUI can do, `devopslings <cmd> <lesson>` can do, which
// is what keeps CI and a student's laptop running identical code paths.
//
// The keymap deliberately matches kubelings and golings — enter plays, i
// inits, t opens a shell, v verifies, / filters, n jumps to the next unsolved
// lesson. These courses are meant to be worked through in sequence, and a key
// that means "shell" in one and "init" in another is a tax on the student for
// no benefit.
package ui

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/madhank93/devopslings/internal/course"
	"github.com/madhank93/devopslings/internal/preflight"
	prog "github.com/madhank93/devopslings/internal/progress"
	"github.com/madhank93/devopslings/internal/runner"
	"github.com/madhank93/devopslings/internal/shell"
)

// maxOutputLines bounds the output pane's scrollback. A `docker compose up`
// that pulls images emits thousands of progress lines, and keeping all of them
// costs memory for text nobody scrolls back to.
const maxOutputLines = 2000

// Run starts the TUI against the course rooted at root.
//
// Mouse cell motion is on so the wheel scrolls; `m` toggles it back off, which
// is the only way to let the terminal's own selection work for copying.
func Run(root string) error {
	m, err := newModel(root)
	if err != nil {
		return err
	}
	_, err = tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}

// pane names the focusable regions. Focus decides which pane the scroll keys
// move, and nothing else.
type pane int

const (
	paneList pane = iota
	paneDetail
	paneOutput
)

// detailView is what the upper-right pane is showing. Hints and the solution
// are behind a keypress for the same reason they are behind <details> in the
// markdown: reading them should be a decision.
type detailView int

const (
	viewTask detailView = iota
	viewHint
	viewSolution
)

func (d detailView) label() string {
	switch d {
	case viewHint:
		return "hint"
	case viewSolution:
		return "solution"
	default:
		return "task"
	}
}

// row is one line of the lesson list: either a module heading or a lesson.
type row struct {
	header string // module heading text, empty for a lesson row
	lesson course.Lesson
}

type model struct {
	root string
	mods []course.Module
	rows []row
	sel  []int // indices into rows that are lessons
	cur  int   // index into sel
	off  int   // first visible row in the list (scroll offset)
	done map[string]prog.State

	detail viewport.Model
	out    viewport.Model
	lines  []string
	spin   spinner.Model
	issues []preflight.Check

	focus pane
	view  detailView

	// showHelp raises the help pop-up. It is a modal rather than a pane mode so
	// the lesson list and the task stay visible behind it — help you have to
	// close to see what you were reading is help you stop opening.
	showHelp bool
	helpVP   viewport.Model

	// filter narrows the list incrementally. While filtering, every printable
	// key is search text — otherwise typing "d" to find "disk-full" would tear
	// down a sandbox.
	filter    string
	filtering bool

	// running is the label of the task in flight ("start disk-full-triage"),
	// empty when idle. One task at a time: two `docker compose up`s against the
	// same project race each other, and the student cannot tell which output
	// belongs to which.
	running string
	started time.Time // when the running task began, for the elapsed clock
	cancel  context.CancelFunc
	lineCh  chan string
	resCh   chan taskDone

	// shellNext chains a shell onto a finishing start, which is what `enter`
	// does: bring the sandbox up, break it, and put the student inside it.
	shellNext   bool
	shellLesson course.Lesson

	// confirmSolution and confirmDown guard the two expensive keys.
	// confirmShared guards starting a lesson while another lesson on the *same*
	// sandbox is still in progress — init_scenario resets that sandbox, so the
	// other lesson's work is destroyed either way; the student should know
	// before it happens rather than after.
	confirmSolution bool
	confirmDown     bool
	confirmShared   bool
	sharedWith      string
	sharedTarget    course.Lesson
	sharedShell     bool

	// mouseOff releases mouse capture so the terminal's own selection works
	// again — with capture on, drags never reach the terminal and copy is dead.
	mouseOff bool

	// mdCache memoises glamour renders, keyed lesson|section|width.
	mdCache map[string]string

	status string // one-line outcome of the last task
	w, h   int
	ready  bool
}

// taskDone carries a finished task back to the update loop.
type taskDone struct {
	kind   string
	lesson course.Lesson
	res    runner.Result
	err    error
}

type lineMsg string
type streamClosed struct{}
type preflightMsg []preflight.Check
type execDone struct{}

func newModel(root string) (*model, error) {
	m := &model{
		root: root,
		spin: spinner.New(spinner.WithSpinner(spinner.Dot)),
	}
	if err := m.reload(); err != nil {
		return nil, err
	}
	m.detail = viewport.New(40, 10)
	m.out = viewport.New(40, 6)
	return m, nil
}

// reload re-reads the course from disk and rebuilds the list. A lesson author
// editing prose in another window presses g and sees it.
func (m *model) reload() error {
	mods, err := course.Discover(m.root)
	if err != nil {
		return err
	}
	m.mods = mods
	m.done = prog.Load(m.root)
	m.mdCache = nil
	m.rebuildRows()
	return nil
}

// rebuildRows derives the visible list from m.mods and the active filter. A
// module header only appears when a lesson under it survives the filter, so a
// narrowed list never shows a heading with nothing beneath it.
func (m *model) rebuildRows() {
	// Keep the selected lesson selected across a filter edit where possible —
	// re-indexing under the cursor is disorienting.
	want := m.current().Name

	m.rows = nil
	m.sel = nil
	for _, mo := range m.mods {
		shown := false
		for _, l := range mo.Lessons {
			if !m.matches(l) {
				continue
			}
			if !shown {
				m.rows = append(m.rows, row{header: fmt.Sprintf("%s — %s", mo.Name, mo.Title)})
				shown = true
			}
			m.rows = append(m.rows, row{lesson: l})
			m.sel = append(m.sel, len(m.rows)-1)
		}
	}

	m.cur = 0
	if want != "" {
		for i, ri := range m.sel {
			if m.rows[ri].lesson.Name == want {
				m.cur = i
				break
			}
		}
	}
	if m.cur >= len(m.sel) {
		m.cur = max(0, len(m.sel)-1)
	}
	m.clampOff()
}

// matches reports whether a lesson survives the active filter. Name, title and
// module title all count, so "ci" finds the CI/CD module and "leaked" finds the
// lesson without the student knowing which field they are searching.
func (m *model) matches(l course.Lesson) bool {
	if m.filter == "" {
		return true
	}
	q := strings.ToLower(m.filter)
	return strings.Contains(strings.ToLower(l.Name), q) ||
		strings.Contains(strings.ToLower(l.Title), q) ||
		strings.Contains(strings.ToLower(l.ModuleTitle), q)
}

// nextUnsolved moves to the next lesson that is not solved, wrapping once.
func (m *model) nextUnsolved() bool {
	n := len(m.sel)
	if n == 0 {
		return false
	}
	for i := 1; i <= n; i++ {
		c := (m.cur + i) % n
		if prog.Get(m.done, m.rows[m.sel[c]].lesson.Name) != prog.Solved {
			m.cur = c
			m.clampOff()
			return true
		}
	}
	return false
}

// clampOff scrolls the list just enough to keep the cursor visible, pulling the
// module header along when the cursor sits directly under it.
func (m *model) clampOff() {
	h := m.listHeight()
	if h <= 0 || len(m.sel) == 0 {
		m.off = 0
		return
	}
	c := m.sel[m.cur]
	top := c
	if top > 0 && m.rows[top-1].header != "" {
		top--
	}
	if top < m.off {
		m.off = top
	}
	if c >= m.off+h {
		m.off = c - h + 1
	}
	m.off = min(m.off, max(0, len(m.rows)-h))
	m.off = max(m.off, 0)
}

func (m *model) current() course.Lesson {
	if len(m.sel) == 0 || m.cur >= len(m.sel) {
		return course.Lesson{}
	}
	return m.rows[m.sel[m.cur]].lesson
}

func (m *model) Init() tea.Cmd {
	// Preflight shells out to docker, which can block for seconds on a daemon
	// that is starting. It runs as a command so the UI draws first.
	return tea.Batch(m.spin.Tick, func() tea.Msg {
		return preflightMsg(preflight.Run(context.Background()).Checks)
	})
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.ready = true
		m.layout()
		return m, nil

	case preflightMsg:
		// Only problems are worth a banner; a wall of ✓ is chrome.
		m.issues = nil
		for _, c := range msg {
			if c.Severity != preflight.OK {
				m.issues = append(m.issues, c)
			}
		}
		m.layout()
		return m, nil

	case spinner.TickMsg:
		if m.running == "" {
			return m, nil
		}
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case lineMsg:
		m.appendLine(string(msg))
		return m, m.waitLine()

	case streamClosed, execDone:
		return m, nil

	case taskDone:
		return m, m.finish(msg)

	case tea.MouseMsg:
		return m, m.mouse(msg)

	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

// mouse maps the wheel: over the list it moves the selection (the list couples
// selection and scroll), over the right panes it scrolls whichever pane the
// pointer is in — hovering, not focus, so scrolling never steals focus.
func (m *model) mouse(msg tea.MouseMsg) tea.Cmd {
	if m.filtering || m.confirmSolution || m.confirmDown || m.confirmShared {
		return nil
	}
	overList := msg.X < listWidth
	switch msg.Button {
	case tea.MouseButtonWheelUp:
		m.wheel(overList, msg.Y, -1)
	case tea.MouseButtonWheelDown:
		m.wheel(overList, msg.Y, 1)
	case tea.MouseButtonLeft:
		if overList && msg.Action == tea.MouseActionPress {
			if i, ok := m.rowAt(msg.Y); ok {
				m.cur = i
				m.clampOff()
				m.view = viewTask
				m.refreshDetail()
			}
		}
	}
	return nil
}

func (m *model) wheel(overList bool, y, step int) {
	switch {
	case overList:
		m.moveSel(step)
	case y < m.detailBottom():
		m.scrollPane(&m.detail, step*3)
	default:
		m.scrollPane(&m.out, step*3)
	}
}

// rowAt maps a terminal row to an index into sel, or false when the click
// landed on a header, on padding, or outside the list.
func (m *model) rowAt(y int) (int, bool) {
	i := m.off + y - m.listTop()
	if i < m.off || i >= len(m.rows) || m.rows[i].header != "" {
		return 0, false
	}
	for si, ri := range m.sel {
		if ri == i {
			return si, true
		}
	}
	return 0, false
}

func (m *model) key(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// The help pop-up owns the keyboard while it is up: it scrolls, and every
	// other key closes it. Anything else would fire an action the student
	// cannot see the consequences of.
	if m.showHelp {
		switch msg.String() {
		case "up", "k":
			m.helpVP.ScrollUp(1)
		case "down", "j":
			m.helpVP.ScrollDown(1)
		case "pgup", "ctrl+u":
			m.helpVP.HalfPageUp()
		case "pgdown", "ctrl+d":
			m.helpVP.HalfPageDown()
		case "ctrl+c":
			return m, tea.Quit
		default:
			m.showHelp = false
			// A pop-up rewrites the middle of the frame and nothing else, so the
			// differential renderer can leave fragments of it behind when it
			// closes. Repaint the lot; it happens once per keypress, not per
			// frame.
			return m, tea.ClearScreen
		}
		return m, nil
	}

	// Filter mode owns the keyboard.
	if m.filtering {
		return m.filterKey(msg)
	}

	// Keys typed faster than the read loop arrive as one KeyRunes carrying
	// several runes. Matching on msg.String() would compare against "/lea" and
	// hit no case at all, so a fast "/" + query would do nothing. Split the
	// burst and handle each key in turn — the second rune may well be search
	// text, because the first one opened the filter.
	if msg.Type == tea.KeyRunes && len(msg.Runes) > 1 {
		var cmds []tea.Cmd
		for _, r := range msg.Runes {
			_, cmd := m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)
	}

	// Confirmations capture keys before anything else.
	switch {
	case m.confirmSolution:
		if k := msg.String(); k == "y" || k == "Y" {
			m.view = viewSolution
			m.refreshDetail()
		}
		m.confirmSolution = false
		return m, tea.ClearScreen

	case m.confirmDown:
		k := msg.String()
		m.confirmDown = false
		if k == "y" || k == "Y" {
			return m, tea.Batch(tea.ClearScreen, m.run("down", m.current()))
		}
		return m, tea.ClearScreen

	case m.confirmShared:
		k := msg.String()
		m.confirmShared = false
		if k == "y" || k == "Y" {
			// The other lesson's sandbox is about to be reset out from under it,
			// so its progress is no longer true. Say so in the file rather than
			// leaving a ◐ that lies.
			_ = prog.Set(m.root, m.sharedWith, prog.None)
			m.done = prog.Load(m.root)
			m.shellNext = m.sharedShell
			m.shellLesson = m.sharedTarget
			return m, tea.Batch(tea.ClearScreen, m.run("start", m.sharedTarget))
		}
		return m, tea.ClearScreen
	}

	if m.running != "" {
		// A task in flight owns the harness; only cancelling and quitting apply.
		switch msg.String() {
		case "ctrl+c", "q":
			m.cancel()
			return m, tea.Quit
		case "esc":
			m.cancel()
			m.status = "cancelling " + m.running + " — the sandbox may be half-built; press r to reset"
		}
		return m, nil
	}

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit

	case "up", "k":
		if m.focus == paneList {
			m.moveSel(-1)
		} else {
			m.scrollFocused(-1)
		}

	case "down", "j":
		if m.focus == paneList {
			m.moveSel(1)
		} else {
			m.scrollFocused(1)
		}

	case "pgup", "ctrl+u":
		m.scrollFocused(-max(m.detail.Height/2, 1))
	case "pgdown", "ctrl+d":
		m.scrollFocused(max(m.detail.Height/2, 1))
	case "g":
		// Reload from disk and jump the focused pane to the top: g is both
		// "refresh" (kubelings) and the vi-ism people reach for.
		_ = m.reload()
		m.refreshDetail()
		m.detail.GotoTop()
	case "G":
		if m.focus == paneOutput {
			m.out.GotoBottom()
		} else {
			m.detail.GotoBottom()
		}

	case "tab":
		m.focus = (m.focus + 1) % 3

	case "esc":
		// One key backs out of whatever narrowed the view: the filter first,
		// then the pane mode.
		if m.filter != "" {
			m.filter = ""
			m.rebuildRows()
		}
		m.view = viewTask
		m.refreshDetail()

	case "/":
		m.filtering = true

	case "n":
		if !m.nextUnsolved() {
			m.status = "every lesson in view is solved — esc clears the filter"
			return m, nil
		}
		m.view = viewTask
		m.refreshDetail()

	case "?":
		m.showHelp = true
		m.helpVP.GotoTop()
		return m, tea.ClearScreen

	case "m":
		m.mouseOff = !m.mouseOff
		if m.mouseOff {
			return m, tea.DisableMouse
		}
		return m, tea.EnableMouseCellMotion

	case "h":
		m.view = viewHint
		m.refreshDetail()

	case "s":
		if m.current().Solution != "" {
			m.confirmSolution = true
			return m, tea.ClearScreen
		} else {
			m.status = "this lesson has no written solution"
		}

	case "enter", " ":
		// Play: start the lesson, then drop into its sandbox.
		return m, m.begin(m.current(), true)

	case "i":
		return m, m.begin(m.current(), false)

	case "t":
		return m, m.shell(m.current())

	case "v":
		return m, m.run("verify", m.current())

	case "r":
		return m, m.run("reset", m.current())

	case "d":
		// `down` removes the stack's volumes, so it discards the scenario the
		// student is standing in. Cheap to redo, expensive to do by accident.
		if m.current().Sandbox.Stack == runner.NoStack {
			m.status = "this lesson has no sandbox to stop"
		} else {
			m.confirmDown = true
			return m, tea.ClearScreen
		}
	}
	return m, nil
}

func (m *model) filterKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyRunes, tea.KeySpace:
		if msg.Type == tea.KeySpace {
			m.filter += " "
		} else {
			m.filter += string(msg.Runes)
		}
		m.rebuildRows()
		m.refreshDetail()
	case tea.KeyBackspace:
		if r := []rune(m.filter); len(r) > 0 {
			m.filter = string(r[:len(r)-1])
		}
		m.rebuildRows()
		m.refreshDetail()
	case tea.KeyEnter:
		m.filtering = false // keep the filter, hand the keyboard back
	case tea.KeyEsc, tea.KeyCtrlC:
		m.filtering, m.filter = false, ""
		m.rebuildRows()
		m.refreshDetail()
	case tea.KeyUp, tea.KeyDown:
		// Narrow, then pick, without leaving the filter.
		step := 1
		if msg.Type == tea.KeyUp {
			step = -1
		}
		m.moveSel(step)
	}
	return m, nil
}

func (m *model) moveSel(step int) {
	next := m.cur + step
	if next < 0 || next >= len(m.sel) {
		return
	}
	m.cur = next
	m.clampOff()
	m.view = viewTask
	m.refreshDetail()
}

func (m *model) scrollFocused(step int) {
	if m.focus == paneOutput {
		m.scrollPane(&m.out, step)
		return
	}
	m.scrollPane(&m.detail, step)
}

func (m *model) scrollPane(v *viewport.Model, step int) {
	if step < 0 {
		v.ScrollUp(-step)
	} else {
		v.ScrollDown(step)
	}
}

// begin starts a lesson, first checking whether another lesson is mid-flight on
// the same sandbox.
//
// Sandboxes are shared: first-pipeline and leaked-secret both live in ci-stack,
// and init_scenario force-pushes over the repo. Starting one destroys the
// other's work, so ask before doing it rather than explaining afterwards.
func (m *model) begin(l course.Lesson, withShell bool) tea.Cmd {
	if !l.HasTasks {
		m.status = l.Name + " is a reading — nothing to start"
		return nil
	}
	if other, clash := m.sharedStackClash(l); clash {
		m.confirmShared = true
		m.sharedWith = other
		m.sharedTarget = l
		m.sharedShell = withShell
		return tea.ClearScreen
	}
	m.shellNext = withShell
	m.shellLesson = l
	return m.run("start", l)
}

// sharedStackClash returns a started lesson that shares l's sandbox, if any.
func (m *model) sharedStackClash(l course.Lesson) (string, bool) {
	if l.Sandbox.Stack == runner.NoStack || l.Sandbox.Stack == "" {
		return "", false
	}
	for _, other := range course.All(m.mods) {
		if other.Name == l.Name || other.Sandbox.Stack != l.Sandbox.Stack {
			continue
		}
		if prog.Get(m.done, other.Name) == prog.Started {
			return other.Name, true
		}
	}
	return "", false
}

// run starts a lesson task in the background and wires its output into the
// output pane.
//
// The runner call blocks, so it goes in a goroutine and reports back through
// resCh; lines arrive on lineCh as they are produced. Both are buffered: a task
// that outputs faster than the UI redraws must not block the process producing
// it.
func (m *model) run(kind string, l course.Lesson) tea.Cmd {
	if m.running != "" {
		m.status = m.running + " is still running — esc cancels it"
		return nil
	}
	if !l.HasTasks && kind != "down" {
		m.status = l.Name + " is a reading — nothing to " + kind
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.running = kind + " " + l.Name
	m.started = time.Now()
	m.status = ""
	m.lines = nil
	m.out.SetContent("")
	m.focus = paneOutput

	lineCh := make(chan string, 256)
	resCh := make(chan taskDone, 1)
	m.lineCh, m.resCh = lineCh, resCh

	// A fresh runner per task: Out is only safe to set on a runner nobody else
	// is using, and this way the closure captures this task's channel.
	r := &runner.Runner{Root: m.root, Out: func(line string) { lineCh <- line }}

	go func() {
		defer close(lineCh)
		var res runner.Result
		var err error
		switch kind {
		case "start":
			res, err = r.Start(ctx, l)
		case "verify":
			res, err = r.Verify(ctx, l)
		case "reset":
			res, err = r.Reset(ctx, l)
		case "down":
			res, err = r.Down(ctx, l.Sandbox.Stack)
		}
		resCh <- taskDone{kind: kind, lesson: l, res: res, err: err}
	}()

	return tea.Batch(m.waitLine(), m.waitResult(), m.spin.Tick)
}

func (m *model) waitLine() tea.Cmd {
	ch := m.lineCh
	return func() tea.Msg {
		line, ok := <-ch
		if !ok {
			return streamClosed{}
		}
		return lineMsg(line)
	}
}

func (m *model) waitResult() tea.Cmd {
	ch := m.resCh
	return func() tea.Msg { return <-ch }
}

// finish records the outcome of a task and updates progress.
//
// Progress moves on the same rules the CLI uses: start and reset mark a lesson
// started, a passing verify marks it solved. A failing verify changes nothing —
// a student who had solved it and broke it again has not un-learned it.
func (m *model) finish(d taskDone) tea.Cmd {
	took := elapsed(time.Since(m.started))
	m.running = ""
	m.cancel = nil
	shell := m.shellNext
	m.shellNext = false

	switch {
	case d.err != nil:
		m.status = "✗ harness error: " + d.err.Error()
	case d.kind == "verify" && d.res.OK:
		_ = prog.Set(m.root, d.lesson.Name, prog.Solved)
		m.status = "PASS — " + d.lesson.Name + " solved in " + took
	case d.kind == "verify":
		if d.res.Reason != "" {
			m.status = "not yet: " + d.res.Reason
		} else {
			m.status = "not yet — the check failed without saying why; that is a lesson bug"
		}
	case !d.res.OK:
		m.status = "✗ " + d.kind + " failed after " + took + " — this is a harness problem, not your answer"
	default:
		if d.kind == "start" || d.kind == "reset" {
			_ = prog.Set(m.root, d.lesson.Name, prog.Started)
			m.status = "✓ " + d.lesson.Name + " is ready in " + took + " — t for a shell, v to verify"
			if d.lesson.InjectsFault {
				m.status += " (this lesson injects a fault at verify time)"
			}
		} else {
			m.status = "✓ " + d.kind + " ok in " + took
		}
	}
	m.done = prog.Load(m.root)

	// enter chains a shell onto a successful start; a failed one leaves the
	// student looking at why instead.
	if shell && d.err == nil && d.res.OK && d.kind == "start" {
		return m.shell(m.shellLesson)
	}
	return nil
}

// shell hands the whole terminal to the student, then takes it back.
//
// tea.ExecProcess suspends the renderer for the duration: a shell needs a real
// TTY, which is exactly what the TUI has taken over.
func (m *model) shell(l course.Lesson) tea.Cmd {
	if m.running != "" {
		m.status = "wait for " + m.running + " to finish"
		return nil
	}
	if !l.HasTasks {
		m.status = l.Name + " is a reading — there is no sandbox to enter"
		return nil
	}
	r := runner.New(m.root)
	c, cleanup, err := r.ShellCmdRC(l, shell.RC(l, m.shellConfig(l)))
	if err != nil {
		m.status = "no shell for this lesson: " + err.Error()
		return nil
	}
	return tea.ExecProcess(c, func(error) tea.Msg {
		// A non-zero exit is the student's last command failing, not a problem
		// with the harness. Nothing to report.
		cleanup()
		return execDone{}
	})
}

// shellConfig describes this shell to the rcfile builder.
func (m *model) shellConfig(l course.Lesson) shell.Config {
	bin, err := os.Executable()
	if err != nil {
		bin = ""
	}
	return shell.Config{
		Root:        m.root,
		Binary:      bin,
		InContainer: l.Sandbox.Service != runner.HostService,
		Width:       max(m.w-4, 60),
	}
}

func (m *model) appendLine(s string) {
	m.lines = append(m.lines, s)
	if len(m.lines) > maxOutputLines {
		m.lines = m.lines[len(m.lines)-maxOutputLines:]
	}
	m.out.SetContent(strings.Join(m.lines, "\n"))
	m.out.GotoBottom()
}

func (m *model) refreshDetail() {
	l := m.current()
	var body string
	switch m.view {
	case viewHint:
		if body = l.Hint; body == "" {
			body = "_This lesson has no hints._"
		}
	case viewSolution:
		if body = l.Solution; body == "" {
			body = "_This lesson has no written solution._"
		}
	default:
		body = l.Task
	}
	key := l.Name + "|" + m.view.label()
	// Wrap two columns short of the pane: glamour adds its own left margin, so
	// rendering at the full width produces lines wider than the pane holds.
	m.detail.SetContent(m.md(key, body, m.detail.Width-2))
	m.detail.GotoTop()
}
