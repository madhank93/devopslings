package course

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot locates the checkout root from the test's working directory.
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

func TestValidLessonName(t *testing.T) {
	cases := map[string]bool{
		"disk-full-triage": true,
		"pid1-signals":     true,
		"a":                true,
		"a.b_c-d":          true,

		// The regex that extracts a lesson name from its directory is happy to
		// produce these, and they all reach a filesystem path.
		"..":          false,
		"../etc":      false,
		"a/b":         false,
		"-flag":       false,
		"":            false,
		"Uppercase":   false,
		"has space":   false,
		"trailing\n":  false,
		"semi;colon":  false,
		"$(injected)": false,
	}
	for name, want := range cases {
		if got := ValidLessonName(name); got != want {
			t.Errorf("ValidLessonName(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestValidSandboxName(t *testing.T) {
	cases := map[string]bool{
		"linux-box": true,
		"ci_stack":  true,
		"none":      true,
		"host":      true,

		"../etc":     false,
		"a/b":        false,
		"":           false,
		"-x":         false,
		"has space":  false,
		"semi;colon": false,
	}
	for name, want := range cases {
		if got := ValidSandboxName(name); got != want {
			t.Errorf("ValidSandboxName(%q) = %v, want %v", name, got, want)
		}
	}
}

// TestDiscover checks the real course on disk. It is a structural test, not a
// fixture test: the thing most likely to break is a lesson someone adds, not
// the parser.
func TestDiscover(t *testing.T) {
	root := repoRoot(t)
	mods, err := Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(mods) == 0 {
		t.Fatal("no modules discovered")
	}

	seen := map[string]string{}
	for _, m := range mods {
		if m.Title == "" {
			t.Errorf("module %s has no title — its 0.index.md is missing or malformed", m.Name)
		}
		if len(m.Lessons) == 0 {
			t.Errorf("module %s has no lessons", m.Name)
		}
		for _, l := range m.Lessons {
			if prev, dup := seen[l.Name]; dup {
				// Lesson names are the CLI's identifier and the progress file's
				// key, so a duplicate silently shadows another lesson.
				t.Errorf("duplicate lesson name %q in %s and %s", l.Name, prev, m.Name)
			}
			seen[l.Name] = m.Name

			if l.Title == "" {
				t.Errorf("%s: no title", l.Name)
			}
			if l.Task == "" {
				t.Errorf("%s: unit-1.md has no task prose — the student is given nothing to do", l.Name)
			}
			if !l.HasTasks {
				continue
			}
			if _, ok := l.Tasks[TaskVerify]; !ok {
				t.Errorf("%s: has tasks but no %s, so it can never be completed", l.Name, TaskVerify)
			}
			if l.Sandbox.Stack == "" {
				t.Errorf("%s: names no sandbox stack", l.Name)
			}
			if !ValidSandboxName(l.Sandbox.Stack) {
				t.Errorf("%s: invalid sandbox stack %q", l.Name, l.Sandbox.Stack)
			}
			if l.Sandbox.Service == "" {
				t.Errorf("%s: names no sandbox service", l.Name)
			}
			for taskName, task := range l.Tasks {
				if task.Run == "" {
					t.Errorf("%s: task %s has an empty run script", l.Name, taskName)
				}
			}
		}
	}
}

// TestEveryRunnableLessonHasHelp guards the thing that makes these lessons
// teachable rather than merely gradeable.
func TestEveryRunnableLessonHasHelp(t *testing.T) {
	root := repoRoot(t)
	mods, err := Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range All(mods) {
		if !l.HasTasks {
			continue
		}
		if l.Hint == "" {
			t.Errorf("%s: no <details> containing a hint — a stuck student has nowhere to go", l.Name)
		}
		if l.Solution == "" {
			t.Errorf("%s: no <details> containing a solution", l.Name)
		}
		if _, err := os.Stat(filepath.Join(l.Dir, "solution", "solve.sh")); err != nil {
			t.Errorf("%s: no solution/solve.sh — the contract test cannot prove it is solvable", l.Name)
		}
	}
}

// TestTaskProseHidesTheAnswer checks that the text shown up front stops at the
// first <details>. A leaked solution is invisible in review and ruins the
// lesson for the reader.
func TestTaskProseHidesTheAnswer(t *testing.T) {
	root := repoRoot(t)
	mods, err := Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range All(mods) {
		if l.Task == "" {
			continue
		}
		low := strings.ToLower(l.Task)
		if strings.Contains(low, "<details") || strings.Contains(low, "</summary>") {
			t.Errorf("%s: task prose leaks into the hints/solution block", l.Name)
		}
	}
}
