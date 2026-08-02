package runner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/madhank93/devopslings/internal/course"
)

// SolutionScript returns the path to a lesson's reference solution, and whether
// it exists.
func SolutionScript(l course.Lesson) (string, bool) {
	p := filepath.Join(l.Dir, "solution", "solve.sh")
	if _, err := os.Stat(p); err != nil {
		return "", false
	}
	return p, true
}

// ContractResult records what happened when a lesson was put through the full
// broken -> solved cycle.
type ContractResult struct {
	Lesson string
	Stages []string // human-readable trace, in order
	Err    error    // nil when the lesson honours its contract
}

// Failed reports whether the contract was violated.
func (c ContractResult) Failed() bool { return c.Err != nil }

// Contract runs the assertion that every lesson in the course must satisfy:
//
//  1. from a clean sandbox, init_scenario establishes the scenario
//  2. verify_done FAILS — proving the lesson is actually broken
//  3. the reference solution is applied
//  4. verify_done PASSES — proving the lesson is actually solvable
//  5. verify_done PASSES a second time — proving the check has no side effects
//
// Step 2 is the one that catches the expensive mistake. A lesson whose check
// passes before the student has done anything is worse than no lesson: it
// teaches that the grader is meaningless. Step 5 catches a check that mutates
// the system it is measuring, which produces failures that look like flakes and
// get "fixed" by rerunning.
func (r *Runner) Contract(ctx context.Context, l course.Lesson) ContractResult {
	res := ContractResult{Lesson: l.Name}
	note := func(f string, a ...any) { res.Stages = append(res.Stages, fmt.Sprintf(f, a...)) }
	fail := func(f string, a ...any) ContractResult {
		res.Err = fmt.Errorf(f, a...)
		return res
	}

	if !l.HasTasks {
		note("reading lesson, nothing to run")
		return res
	}
	if _, ok := l.Tasks[course.TaskVerify]; !ok {
		return fail("has tasks but no %s — it can never be completed", course.TaskVerify)
	}
	sol, ok := SolutionScript(l)
	if !ok {
		return fail("no solution/solve.sh — the contract cannot be checked, and nobody can confirm the lesson is solvable")
	}

	// 1. Clean slate, then set the scenario up.
	if _, err := r.Down(ctx, l.Sandbox.Stack); err != nil {
		return fail("teardown before start: %w", err)
	}
	start, err := r.Start(ctx, l)
	if err != nil {
		return fail("start: %w", err)
	}
	if !start.OK {
		return fail("init_scenario failed:\n%s", tail(start.Output, 20))
	}
	note("init_scenario ok")

	// 2. It must be broken.
	pre, err := r.Verify(ctx, l)
	if err != nil {
		return fail("verify (pre): %w", err)
	}
	if pre.OK {
		return fail("verify_done PASSED before the solution was applied — the lesson is not actually broken:\n%s",
			tail(pre.Output, 10))
	}
	if pre.Reason == "" {
		return fail("verify_done failed without a 'not yet:' line — the student is told they are wrong but not why:\n%s",
			tail(pre.Output, 10))
	}
	note("broken as intended (%s)", pre.Reason)

	// 3. Apply the reference solution.
	body, err := os.ReadFile(sol)
	if err != nil {
		return fail("read solution: %w", err)
	}
	service := l.Sandbox.Service
	if service == "" {
		service = HostService
	}
	app, err := r.Exec(ctx, l.Sandbox.Stack, service, string(body), r.workDir(l), DefaultTimeout)
	if err != nil {
		return fail("apply solution: %w", err)
	}
	if !app.OK {
		return fail("the reference solution itself failed:\n%s", tail(app.Output, 20))
	}
	note("solution applied")

	// 4. It must now be solved.
	post, err := r.Verify(ctx, l)
	if err != nil {
		return fail("verify (post): %w", err)
	}
	if !post.OK {
		return fail("verify_done FAILED after the reference solution — the lesson is not solvable as written:\n%s",
			tail(post.Output, 20))
	}
	note("solvable")

	// 5. And the check must not have changed anything by measuring it.
	again, err := r.Verify(ctx, l)
	if err != nil {
		return fail("verify (idempotency): %w", err)
	}
	if !again.OK {
		return fail("verify_done passed once and failed on a second run — the check has side effects:\n%s",
			tail(again.Output, 20))
	}
	note("check is idempotent")

	return res
}

// tail returns the last n lines of s, for error messages that should not paste
// an entire build log into a test failure.
func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
