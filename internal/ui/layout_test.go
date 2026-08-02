package ui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// TestViewFitsTheTerminal is the regression test for two layout bugs that both
// showed as "the header is missing": a pane wider than its column wraps the row
// it is on, and every wrapped row pushes the frame one line further down until
// the top scrolls away.
//
// It checks several sizes because the bug only appeared at some of them.
func TestViewFitsTheTerminal(t *testing.T) {
	sizes := []struct{ w, h int }{{120, 40}, {100, 30}, {80, 24}, {200, 60}, {60, 20}}
	for _, s := range sizes {
		m, err := newModel(repoRoot(t))
		if err != nil {
			t.Fatal(err)
		}
		m.Update(tea.WindowSizeMsg{Width: s.w, Height: s.h})
		lines := strings.Split(m.View(), "\n")

		if len(lines) > s.h {
			t.Errorf("%dx%d: view is %d lines, terminal holds %d", s.w, s.h, len(lines), s.h)
		}
		for i, l := range lines {
			// One column of slack: ambiguous-width glyphs (◐, ✓, box drawing)
			// are drawn double by some terminals, and a row that exactly fills
			// the width there would wrap.
			if w := lipgloss.Width(l); w >= s.w {
				t.Errorf("%dx%d: line %d is %d wide, terminal is %d", s.w, s.h, i, w, s.w)
			}
		}
		if !strings.Contains(lines[0], "devopslings") {
			t.Errorf("%dx%d: first line is not the header: %q", s.w, s.h, lines[0])
		}
	}
}

// TestBarRendersAtItsWidth: the meter is hand-rolled, so its width is a promise
// the header layout depends on.
func TestBarRendersAtItsWidth(t *testing.T) {
	for _, ratio := range []float64{0, 0.01, 0.5, 0.999, 1} {
		if got := lipgloss.Width(bar(ratio, 20)); got != 20 {
			t.Errorf("bar(%v, 20) is %d cells wide", ratio, got)
		}
	}
	if strings.Count(bar(1, 10), "█") != 10 {
		t.Error("a full bar is not full")
	}
	if strings.Count(bar(0, 10), "░") != 10 {
		t.Error("an empty bar is not empty")
	}
}
