// Package course discovers the devopslings course structure (modules and
// lessons) from courses/devopslings on disk. It is read-only — executing a
// lesson is the runner's job.
//
// The layout and frontmatter contract are deliberately close to kubelings so
// the two courses stay legible to the same reader. The one structural
// difference is the substrate: kubelings lessons name an iximiuz `playground`,
// devopslings lessons name a local compose `sandbox`.
package course

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Task names recognised in a lesson's `tasks:` block.
//
// InitScenario and VerifyDone carry the same meaning they do in kubelings.
// InjectFault is new, and is what lets modules 14-18 exist: it runs after the
// student's work and before the check, turning "make the broken thing work"
// into "prove the working thing survives". A lesson that declares it is asking
// to be graded on resilience, not on end-state.
const (
	TaskInit   = "init_scenario"
	TaskFault  = "inject_fault"
	TaskVerify = "verify_done"
)

// Sandbox identifies the compose stack a lesson runs against and which service
// its task scripts exec into.
type Sandbox struct {
	Stack   string `yaml:"stack"`
	Service string `yaml:"service"`
}

// Task is one script in a lesson's `tasks:` block.
type Task struct {
	// Init marks the task that establishes the scenario. Kept for parity with
	// the kubelings frontmatter, where the platform uses it to decide what to
	// run on playground start.
	Init bool `yaml:"init"`

	// Run is the shell script, executed with `set -euo pipefail` inside the
	// task's service.
	Run string `yaml:"run"`

	// Needs names tasks that must have run first. Documentation for the reader
	// and an ordering assertion for the contract test; the runner's order is
	// fixed (init -> fault -> verify).
	Needs []string `yaml:"needs"`

	// Service overrides the lesson-level sandbox service for this task alone.
	// Fault injection usually runs somewhere other than the app under test —
	// against toxiproxy's admin API, or on the host to kill a container.
	Service string `yaml:"service"`

	// TimeoutSeconds bounds the task. Zero means the runner's default.
	TimeoutSeconds int `yaml:"timeout_seconds"`
}

// Lesson is one runnable (or content-only) scenario.
type Lesson struct {
	Module      string // module dir name, e.g. "module-01"
	ModuleTitle string
	Order       int    // numeric prefix of the lesson dir
	Name        string // dir basename minus "N.", e.g. "disk-full-triage"
	Title       string
	Description string
	Sandbox     Sandbox
	Dir         string // absolute lesson dir
	HasTasks    bool
	Type        string // "lab" | "replay" | "drill" | "read"
	Source      string // citation URL for replay lessons

	// InjectsFault reports whether the lesson declares an inject_fault task.
	// The UI says so up front: a student should know a fault is coming before
	// they are graded on surviving it, not after.
	InjectsFault bool

	// TimingSensitive marks a lesson whose check measures latency or
	// throughput. These are graded against wall-clock numbers and so are the
	// only lessons that can fail for reasons other than the student's work.
	// CI runs them serially; the UI warns that a loaded machine skews results.
	TimingSensitive bool

	// Tasks are the lesson's scripts, keyed by TaskInit/TaskFault/TaskVerify.
	Tasks map[string]Task

	Task     string // unit prose up to the first <details>
	Hint     string
	Solution string
}

// Module groups lessons.
type Module struct {
	Name    string
	Title   string
	Order   int
	Lessons []Lesson
}

type frontmatter struct {
	Title           string          `yaml:"title"`
	Description     string          `yaml:"description"`
	Name            string          `yaml:"name"`
	Source          string          `yaml:"source"`
	Sandbox         Sandbox         `yaml:"sandbox"`
	Tasks           map[string]Task `yaml:"tasks"`
	TimingSensitive bool            `yaml:"timingSensitive"`
}

var (
	moduleDirRe = regexp.MustCompile(`^module-(\d+)$`)
	lessonDirRe = regexp.MustCompile(`^(\d+)\.(.+)$`)

	// lessonNameRe is the shape a lesson name must have to be usable. Names are
	// joined into filesystem paths and passed to the runner, and lessonDirRe's
	// `(.+)` is happy to yield ".." (from a directory named "1...") or a name
	// containing a slash. Malformed directories are skipped rather than
	// rejected: one bad directory should not stop the course from loading.
	lessonNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*$`)

	// Sandbox stack and service names reach a compose invocation, so they get
	// the same treatment.
	sandboxNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)
)

// ValidLessonName reports whether name is safe to join into a path.
func ValidLessonName(name string) bool {
	return name != ".." && lessonNameRe.MatchString(name)
}

// ValidSandboxName reports whether a stack or service name is safe to hand to
// docker compose.
func ValidSandboxName(name string) bool {
	return sandboxNameRe.MatchString(name)
}

// CourseDir returns courses/devopslings under root.
func CourseDir(root string) string { return filepath.Join(root, "courses", "devopslings") }

// SandboxDir returns the compose stack directory for a lesson's sandbox.
func SandboxDir(root, stack string) string { return filepath.Join(root, "sandboxes", stack) }

// Discover scans the course and returns modules in order, each with ordered
// lessons.
func Discover(root string) ([]Module, error) {
	base := CourseDir(root)
	entries, err := os.ReadDir(base)
	if err != nil {
		return nil, err
	}
	var mods []Module
	for _, e := range entries {
		if !e.IsDir() || !moduleDirRe.MatchString(e.Name()) {
			continue
		}
		mo, _ := strconv.Atoi(moduleDirRe.FindStringSubmatch(e.Name())[1])
		m := Module{Name: e.Name(), Order: mo}
		if fm, err := readFrontmatter(filepath.Join(base, e.Name(), "0.index.md")); err == nil {
			m.Title = fm.Title
		}
		lessons, _ := os.ReadDir(filepath.Join(base, e.Name()))
		for _, le := range lessons {
			if !le.IsDir() {
				continue
			}
			mm := lessonDirRe.FindStringSubmatch(le.Name())
			if mm == nil || !ValidLessonName(mm[2]) {
				continue
			}
			ldir := filepath.Join(base, e.Name(), le.Name())
			fm, err := readFrontmatter(filepath.Join(ldir, "index.md"))
			if err != nil {
				continue
			}
			order, _ := strconv.Atoi(mm[1])
			ls := Lesson{
				Module: e.Name(), ModuleTitle: m.Title, Order: order,
				Name: mm[2], Title: fm.Title,
				Description:     strings.TrimSpace(fm.Description),
				Sandbox:         fm.Sandbox,
				Dir:             ldir,
				HasTasks:        len(fm.Tasks) > 0,
				Source:          strings.TrimSpace(fm.Source),
				TimingSensitive: fm.TimingSensitive,
				Tasks:           fm.Tasks,
			}
			_, ls.InjectsFault = fm.Tasks[TaskFault]
			ls.Type = lessonType(ls)

			unit := filepath.Join(ldir, "unit-1.md")
			ls.Task = extractTask(unit)
			ls.Hint = extractDetails(unit, "hint")
			ls.Solution = extractDetails(unit, "solution")
			m.Lessons = append(m.Lessons, ls)
		}
		sort.Slice(m.Lessons, func(i, j int) bool { return m.Lessons[i].Order < m.Lessons[j].Order })
		mods = append(mods, m)
	}
	sort.Slice(mods, func(i, j int) bool { return mods[i].Order < mods[j].Order })
	return mods, nil
}

// Find returns the lesson with the given name, searching every module.
func Find(mods []Module, name string) (Lesson, bool) {
	for _, m := range mods {
		for _, l := range m.Lessons {
			if l.Name == name {
				return l, true
			}
		}
	}
	return Lesson{}, false
}

// All flattens modules into a single ordered lesson list.
func All(mods []Module) []Lesson {
	var out []Lesson
	for _, m := range mods {
		out = append(out, m.Lessons...)
	}
	return out
}

// lessonType classifies a lesson for the UI:
//
//	read   — guided reading, no runnable tasks
//	replay — replay of a real, cited production incident (incident-* slug)
//	drill  — synthetic composite failure pattern (pattern-* slug)
//	lab    — standard hands-on concept lesson
func lessonType(l Lesson) string {
	switch {
	case !l.HasTasks:
		return "read"
	case strings.HasPrefix(l.Name, "incident-"):
		return "replay"
	case strings.HasPrefix(l.Name, "pattern-"):
		return "drill"
	default:
		return "lab"
	}
}

// readFrontmatter parses the YAML block between the first two "---" lines.
func readFrontmatter(path string) (frontmatter, error) {
	var fm frontmatter
	b, err := os.ReadFile(path)
	if err != nil {
		return fm, err
	}
	lines := strings.Split(string(b), "\n")
	start, end := -1, -1
	for i, l := range lines {
		if strings.TrimRight(l, " \t") == "---" {
			if start == -1 {
				start = i
			} else {
				end = i
				break
			}
		}
	}
	if start == -1 || end == -1 {
		return fm, yaml.Unmarshal(b, &fm) // best effort
	}
	block := strings.Join(lines[start+1:end], "\n")
	return fm, yaml.Unmarshal([]byte(block), &fm)
}

// extractTask returns the unit prose (after frontmatter) up to the first
// <details> block — i.e. the situation and the objectives, without the answers.
func extractTask(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(b), "\n")
	start, dashes := 0, 0
	for i, l := range lines {
		if strings.TrimRight(l, " \t") == "---" {
			dashes++
			if dashes == 2 {
				start = i + 1
				break
			}
		}
	}
	var out []string
	for _, l := range lines[start:] {
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(l)), "<details") {
			break
		}
		out = append(out, l)
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}

// extractDetails returns the markdown body of a <details> whose <summary>
// contains the given keyword (case-insensitive), with the tags stripped.
func extractDetails(path, keyword string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	text := string(b)
	low := strings.ToLower(text)
	kw := strings.ToLower(keyword)
	for searchFrom := 0; ; {
		open := strings.Index(low[searchFrom:], "<details>")
		if open == -1 {
			return ""
		}
		open += searchFrom
		closeAt := strings.Index(low[open:], "</details>")
		if closeAt == -1 {
			return ""
		}
		closeAt += open
		block := text[open:closeAt]
		if strings.Contains(strings.ToLower(block), kw) {
			body := block
			if i := strings.Index(strings.ToLower(body), "</summary>"); i != -1 {
				body = body[i+len("</summary>"):]
			} else {
				body = strings.TrimPrefix(body, "<details>")
			}
			return strings.TrimSpace(body)
		}
		searchFrom = closeAt + len("</details>")
	}
}
