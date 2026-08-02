// Package progress reads and writes per-lesson progress markers.
//
// State lives in .devopslings/progress.tsv (<lesson>\t<state>\t<epoch>), which
// is gitignored — `git pull` must never touch a student's progress. The format
// is line-oriented and human-readable on purpose: when something goes wrong,
// the fix should be an edit, not a support request.
package progress

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type State string

const (
	None    State = "none"
	Started State = "started"
	Solved  State = "solved"
)

// Marker returns the glyph for a state.
func (s State) Marker() string {
	switch s {
	case Solved:
		return "✓"
	case Started:
		return "◐"
	default:
		return "◌"
	}
}

func file(root string) string { return filepath.Join(root, ".devopslings", "progress.tsv") }

// Load reads the progress map (lesson -> state). A missing file is an empty
// map, not an error: the first run is the common case.
func Load(root string) map[string]State {
	m := map[string]State{}
	b, err := os.ReadFile(file(root))
	if err != nil {
		return m
	}
	for line := range strings.SplitSeq(string(b), "\n") {
		f := strings.Split(line, "\t")
		if len(f) >= 2 && f[0] != "" {
			m[f[0]] = State(f[1])
		}
	}
	return m
}

// Get returns the state for a lesson (None if unknown).
func Get(m map[string]State, lesson string) State {
	if s, ok := m[lesson]; ok {
		return s
	}
	return None
}

// Set writes a lesson's state (last-write-wins). None removes the row.
//
// Rows are sorted before writing so the file does not churn between saves —
// map iteration order would otherwise reshuffle it every time and make any
// diff of it useless.
func Set(root, lesson string, s State) error {
	cur := Load(root)
	if s == None {
		delete(cur, lesson)
	} else {
		cur[lesson] = s
	}
	names := make([]string, 0, len(cur))
	for l := range cur {
		names = append(names, l)
	}
	sort.Strings(names)

	var b strings.Builder
	now := time.Now().Unix()
	for _, l := range names {
		fmt.Fprintf(&b, "%s\t%s\t%d\n", l, cur[l], now)
	}
	if err := os.MkdirAll(filepath.Dir(file(root)), 0o755); err != nil {
		return err
	}
	return os.WriteFile(file(root), []byte(b.String()), 0o644)
}

// Counts returns how many of the given lessons are solved and started.
func Counts(m map[string]State, lessons []string) (solved, started int) {
	for _, l := range lessons {
		switch Get(m, l) {
		case Solved:
			solved++
		case Started:
			started++
		}
	}
	return solved, started
}
