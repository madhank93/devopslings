#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The four missing shapes, each run once. Only the soak holds traffic long
# enough for quote's per-second filters to pile up past its memory limit.
# The breakpoint aborts on the first percent of failures; the rate it had
# reached is its start plus 20 a second for every second it ran.
# Runs on the host with cwd = sandboxes/chaos-stack.
set -uo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.load-test-shapes
lesson=$1
cp "$lesson"/solution/{soak,spike,stress,breakpoint}.js answers/
for shape in ramp spike stress breakpoint soak; do
  bash "$lesson/files/run.sh" "$shape" >/dev/null 2>&1 || true  # k6 exits 99 when a threshold fails
done
bp=$(jq -r '.metrics.http_reqs | 100 + 20 * (.count / .rate) | round' answers/breakpoint.json)
cat > answers/shapes.txt <<TXT
only_one=soak
failure=quote leaks memory under steady traffic: after about a minute it passes its limit, is killed and restarts, and requests fail while it is down.
breakpoint_rps=$bp
TXT
