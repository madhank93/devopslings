// Package md renders lesson markdown to styled terminal output.
//
// It exists as its own package because two very different callers need the same
// rendering: the TUI's panes, and the files the sandbox shell cats when a
// student types `task`. Prose that reads one way in the UI and another in the
// shell is a bug people notice.
package md

import (
	"os"
	"strings"

	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/glamour/ansi"
	"github.com/charmbracelet/glamour/styles"
	"github.com/muesli/termenv"
	"golang.org/x/term"
)

// style is glamour's dark style with the literal heading prefixes ("# ", "## ",
// …) stripped — those are the raw markers the render exists to remove.
// Headings keep their weight and colour, just without the hashes.
var style = func() ansi.StyleConfig {
	s := styles.DarkStyleConfig
	s.H1.Prefix, s.H2.Prefix, s.H3.Prefix = "", "", ""
	s.H4.Prefix, s.H5.Prefix, s.H6.Prefix = "", "", ""
	return s
}()

// Render turns lesson prose into styled ANSI wrapped to width.
//
// The style and colour profile are pinned rather than auto-detected: glamour's
// auto style falls back to a "notty" render whenever stdout is not a terminal,
// and stdout is not a terminal when the output goes into a bubbletea string or
// a file the shell later cats. Auto-detection would silently leave every `##`
// and `**` as literal text, which is the exact bug this function prevents.
//
// Any failure returns the source unchanged: plain, but readable.
func Render(src string, width int) string {
	if strings.TrimSpace(src) == "" {
		return src
	}
	if width < 20 {
		width = 80
	}
	r, err := glamour.NewTermRenderer(
		glamour.WithStyles(style),
		glamour.WithColorProfile(termenv.ANSI256),
		glamour.WithWordWrap(width),
		glamour.WithEmoji(),
	)
	if err != nil {
		return src
	}
	out, err := r.Render(src)
	if err != nil {
		return src
	}
	// glamour pads with blank lines; trim so the text sits flush.
	return strings.Trim(out, "\n")
}

// TerminalWidth is the width to wrap shell output to, read from stdout with a
// fallback for the non-terminal case.
func TerminalWidth() int {
	if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 20 {
		return w
	}
	return 100
}
