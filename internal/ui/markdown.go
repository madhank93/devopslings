package ui

import (
	"fmt"
	"strings"

	"github.com/madhank93/devopslings/internal/md"
)

// md renders markdown memoised per key and width.
//
// Re-rendering a whole lesson body on every cursor move is the only real cost
// of showing prose in a pane, and it is perfectly cacheable. The cache is
// dropped by reload() and by a resize, because the text on disk is what a
// lesson author edits while watching this, and renders are width-specific.
func (m *model) md(key, src string, width int) string {
	if strings.TrimSpace(src) == "" {
		return ""
	}
	ck := fmt.Sprintf("%s|%d", key, width)
	if out, ok := m.mdCache[ck]; ok {
		return out
	}
	out := md.Render(src, width)
	if m.mdCache == nil {
		m.mdCache = map[string]string{}
	}
	m.mdCache[ck] = out
	return out
}
