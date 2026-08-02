package ui

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// TestOverlayKeepsTheFrameSize is the contract that matters. A composite one
// line taller or one column wider than the frame wraps, and a wrapped frame
// scrolls the header off the top — this package's recurring bug.
func TestOverlayKeepsTheFrameSize(t *testing.T) {
	base := strings.TrimRight(strings.Repeat(strings.Repeat("x", 60)+"\n", 20), "\n")
	box := modal("title", "body text", "y yes · N no", 40)

	for _, at := range [][2]int{{0, 0}, {10, 5}, {55, 18}, {-3, -2}, {200, 200}} {
		got := overlay(base, box, at[0], at[1])
		if lines := len(strings.Split(got, "\n")); lines != 20 {
			t.Errorf("at %v: %d lines, want 20", at, lines)
		}
		for i, l := range strings.Split(got, "\n") {
			if w := lipgloss.Width(l); w > 60 && at[0]+lipgloss.Width(box) <= 60 {
				t.Errorf("at %v: line %d is %d wide, base is 60", at, i, w)
			}
		}
	}
}

// TestOverlayPastesTheBoxAndKeepsTheEdges: the pop-up must be readable, and the
// frame either side of it must survive.
func TestOverlayPastesTheBoxAndKeepsTheEdges(t *testing.T) {
	base := strings.TrimRight(strings.Repeat("LLLLLLLLLLMMMMMMMMMMRRRRRRRRRR\n", 6), "\n")
	got := overlay(base, "[box]", 10, 2)
	lines := strings.Split(got, "\n")

	if !strings.Contains(lines[2], "[box]") {
		t.Errorf("box was not pasted: %q", lines[2])
	}
	if !strings.HasPrefix(lines[2], "LLLLLLLLLL") {
		t.Errorf("the frame left of the box was lost: %q", lines[2])
	}
	if !strings.HasSuffix(lines[2], "RRRRRRRRRR") {
		t.Errorf("the frame right of the box was lost: %q", lines[2])
	}
	if lines[1] != "LLLLLLLLLLMMMMMMMMMMRRRRRRRRRR" {
		t.Errorf("a row outside the box changed: %q", lines[1])
	}
}

// TestOverlaySurvivesStyledLines: cutting a line on byte offsets tears a colour
// sequence in half and bleeds it across the rest of the screen.
func TestOverlaySurvivesStyledLines(t *testing.T) {
	styled := lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Render(strings.Repeat("g", 40))
	base := styled + "\n" + styled
	got := overlay(base, "XX", 10, 0)

	if lipgloss.Width(strings.Split(got, "\n")[0]) != 40 {
		t.Errorf("styled line changed width: %d", lipgloss.Width(strings.Split(got, "\n")[0]))
	}
	if !strings.Contains(got, "XX") {
		t.Error("box did not land on the styled line")
	}
}

func TestElapsed(t *testing.T) {
	cases := map[time.Duration]string{
		900 * time.Millisecond:         "0s",
		42 * time.Second:               "42s",
		61 * time.Second:               "1m01s",
		9*time.Minute + 30*time.Second: "9m30s",
	}
	for d, want := range cases {
		if got := elapsed(d); got != want {
			t.Errorf("elapsed(%v) = %q, want %q", d, got, want)
		}
	}
}
