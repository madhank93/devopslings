package main

import (
	"strings"
	"testing"
)

const fixture = "- **slug** *(tier · status)* — template, outside any module.\n" +
	"## 01 — One\n" +
	"- **a** *(intro · shipped)* — x\n" +
	"- **b** *(deep · drill · shipped)* — x\n" +
	"## 02 — Two\n" +
	"- **c** *(core)* — x\n" +
	"- **d** *(deep · blocked)* — x\n" +
	"## 27 — Capstone\n" +
	"- **stage-1** *(core)* — not an exercise\n" +
	"## Sources\n" +
	"- **e** *(core)* — outside any module\n"

func TestRender(t *testing.T) {
	got := render(parse(fixture))
	for _, want := range []string{
		"**4 exercises** across 2 modules",
		"2 shipped, 1 blocked, 1 specified",
		"1 intro · 1 core · 2 deep · 0 architect",
		"Complete modules: 01.",
		"01 2/2 · 02 0/2",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
}
