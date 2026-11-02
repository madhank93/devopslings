// Command counts derives exercise totals from the entries in EXERCISES.md and
// writes them between the <!-- counts --> markers in the course docs. With
// -check it fails instead of writing, so CI catches a doc that has drifted.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const source = "EXERCISES.md"

// capstoneModule holds stages, which are not counted as exercises.
const capstoneModule = "27"

var (
	moduleRe = regexp.MustCompile(`^## (\d\d) — `)
	entryRe  = regexp.MustCompile(`^- \*\*([a-z0-9-]+)\*\* \*\(([^)]*)\)\*`)
	blockRe  = regexp.MustCompile(`(?s)<!-- counts -->.*?<!-- /counts -->`)
)

type entry struct{ slug, module, tier, status string }

// parse returns every exercise entry in src, in document order.
func parse(src string) []entry {
	var out []entry
	module := ""
	for _, line := range strings.Split(src, "\n") {
		if m := moduleRe.FindStringSubmatch(line); m != nil {
			module = m[1]
			continue
		}
		if strings.HasPrefix(line, "## ") {
			module = ""
		}
		m := entryRe.FindStringSubmatch(line)
		if m == nil || module == "" || module == capstoneModule {
			continue
		}
		e := entry{slug: m[1], module: module}
		for i, f := range strings.Split(m[2], " · ") {
			if i == 0 {
				e.tier = f
			} else if f == "shipped" || f == "blocked" {
				e.status = f
			}
		}
		out = append(out, e)
	}
	return out
}

// render formats the block written into every doc.
func render(entries []entry) string {
	tiers := map[string]int{}
	total, shipped := map[string]int{}, map[string]int{}
	var order []string
	allShipped, blocked := 0, 0
	for _, e := range entries {
		if total[e.module] == 0 {
			order = append(order, e.module)
		}
		total[e.module]++
		tiers[e.tier]++
		switch e.status {
		case "shipped":
			shipped[e.module]++
			allShipped++
		case "blocked":
			blocked++
		}
	}
	var perModule, complete []string
	for _, m := range order {
		perModule = append(perModule, fmt.Sprintf("%s %d/%d", m, shipped[m], total[m]))
		if shipped[m] == total[m] {
			complete = append(complete, m)
		}
	}
	return fmt.Sprintf(`<!-- counts -->
**%d exercises** across %d modules, drills included, capstone stages not: %d shipped, %d blocked, %d specified.

By tier: %d intro · %d core · %d deep · %d architect.

Complete modules: %s.

Shipped per module: %s.
<!-- /counts -->`,
		len(entries), len(order), allShipped, blocked, len(entries)-allShipped-blocked,
		tiers["intro"], tiers["core"], tiers["deep"], tiers["architect"],
		strings.Join(complete, ", "), strings.Join(perModule, " · "))
}

// missingLessons lists shipped entries with no lesson directory under root.
func missingLessons(entries []entry, root string) []string {
	var out []string
	for _, e := range entries {
		if e.status != "shipped" {
			continue
		}
		pattern := filepath.Join(root, "module-"+e.module, "*."+e.slug)
		if found, _ := filepath.Glob(pattern); len(found) == 0 {
			out = append(out, e.slug)
		}
	}
	return out
}

func main() {
	check := flag.Bool("check", false, "fail if a doc is out of date instead of writing")
	flag.Parse()

	src, err := os.ReadFile(source)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	entries := parse(string(src))
	if missing := missingLessons(entries, "courses/devopslings"); len(missing) > 0 {
		fmt.Fprintln(os.Stderr, "marked shipped but no lesson directory:", strings.Join(missing, ", "))
		os.Exit(1)
	}

	block := render(entries)
	failed := false
	for _, path := range []string{"README.md", "CURRICULUM.md", source} {
		doc, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if !blockRe.Match(doc) {
			fmt.Fprintln(os.Stderr, path+": no counts block")
			os.Exit(1)
		}
		updated := blockRe.ReplaceAllLiteralString(string(doc), block)
		if updated == string(doc) {
			continue
		}
		if *check {
			fmt.Fprintln(os.Stderr, path+": counts are stale, run: go run ./cmd/counts")
			failed = true
			continue
		}
		if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	if failed {
		os.Exit(1)
	}
}
