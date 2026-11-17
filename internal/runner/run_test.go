package runner

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

// A helper that escapes the process group keeps the output pipe open; run
// must still return promptly, and a clean exit must still count as success.
func TestRunDetachedHelperDoesNotHang(t *testing.T) {
	helper := `perl -e 'setpgrp(0,0); sleep 30' &`
	cases := []struct {
		name   string
		script string
		budget time.Duration
		ok     bool
	}{
		{"timeout", helper + " sleep 30", time.Second, false},
		{"clean exit", helper + " exit 0", 20 * time.Second, true},
	}
	for _, tc := range cases {
		start := time.Now()
		_, ok := run(context.Background(), exec.Command("bash", "-c", tc.script), tc.budget, nil)
		if d := time.Since(start); d > 15*time.Second {
			t.Errorf("%s: run took %s", tc.name, d)
		}
		if ok != tc.ok {
			t.Errorf("%s: ok = %v, want %v", tc.name, ok, tc.ok)
		}
	}
}
