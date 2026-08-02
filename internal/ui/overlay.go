package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// overlay composites box on top of base at (x, y), returning a block with
// base's exact dimensions.
//
// Bubble Tea has no window system: View returns one string, and anything that
// looks like a pop-up is this — cut a hole in the rendered frame and paste. The
// cutting has to be ANSI-aware, because a line is a mix of printable cells and
// escape sequences that occupy none, and slicing on byte offsets tears a colour
// sequence in half and bleeds it across the rest of the screen.
//
// Keeping base's dimensions is the whole contract: a composite one line taller
// than the terminal scrolls the header away, which is the bug this package has
// already had twice.
func overlay(base, box string, x, y int) string {
	baseLines := strings.Split(base, "\n")
	boxLines := strings.Split(box, "\n")
	if len(boxLines) == 0 {
		return base
	}
	// Clamp into the frame. A caller that centres a box wider than the terminal
	// would otherwise hand back lines wider than the screen, which wraps — and
	// a wrapped frame is the bug this function is careful about.
	baseW := lipgloss.Width(base)
	x = max(x, 0)
	y = max(y, 0)
	boxW := min(lipgloss.Width(box), max(baseW-x, 0))
	if boxW == 0 {
		return base
	}

	for i, line := range boxLines {
		row := y + i
		if row < 0 || row >= len(baseLines) {
			continue
		}
		under := baseLines[row]
		underW := lipgloss.Width(under)

		// Left of the box, then the box, then whatever of the base survives to
		// its right. TruncateLeft counts cells, so the right-hand piece resumes
		// at the correct column even when the base line is full of styling.
		left := ansi.Truncate(under, x, "")
		if w := lipgloss.Width(left); w < x {
			left += strings.Repeat(" ", x-w)
		}
		var right string
		if underW > x+boxW {
			right = ansi.TruncateLeft(under, x+boxW, "")
		}

		// Pad a short box line so the frame behind it cannot show through the
		// middle of the pop-up, and cut a long one so it cannot push the row
		// past the frame's width.
		switch w := lipgloss.Width(line); {
		case w < boxW:
			line += strings.Repeat(" ", boxW-w)
		case w > boxW:
			line = ansi.Truncate(line, boxW, "")
		}
		baseLines[row] = left + line + right
	}
	return strings.Join(baseLines, "\n")
}

// center returns the top-left corner that puts a box of the given size in the
// middle of w×h, clamped so it never starts off-screen.
func center(w, h, boxW, boxH int) (int, int) {
	return max((w-boxW)/2, 0), max((h-boxH)/2, 0)
}

// modal renders a titled box for overlaying: a prompt, its body, and the keys
// that answer it.
func modal(title, body, keys string, width int) string {
	inner := max(min(width-6, 72), 24)
	content := titleStyle.Render(title)
	if body != "" {
		content += "\n\n" + lipgloss.NewStyle().Width(inner).Render(body)
	}
	if keys != "" {
		content += "\n\n" + keys
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cAmber).
		Padding(0, 2).
		Width(inner).
		MaxWidth(inner + 6).
		Render(content)
}
