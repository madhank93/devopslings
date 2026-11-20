# Shared by stage 2's init, fault and check. Source it after files/lib.sh.
M="$DEVOPSLINGS_ROOT/courses/devopslings/module-27"
F="$M/02.stage-2-break-it/files"
S="$DEVOPSLINGS_ROOT/scratch/stage-2-break-it"
FAULTS="health drift retention cache split"
repo_url="http://devops:devopslings@127.0.0.1:3000/${repo}.git"

# The drawn fault, from the digest init left in .state; empty when there is
# none. The digest keeps the answer out of a casual `cat`, nothing more.
drawn_fault() {
  _d=$(cat "$S/.state" 2>/dev/null || true)
  for _f in $FAULTS; do
    [ "$(printf '%s' "$_f" | sha256sum | awk '{print $1}')" = "$_d" ] && echo "$_f"
  done
  return 0
}

# Starts the pricing service checkout calls, if it is not running, and puts
# its price and deny list back to their defaults.
pricing_up() {
  if [ "$(docker inspect -f '{{.State.Running}}' capstone-pricing 2>/dev/null || true)" != true ]; then
    docker rm -f capstone-pricing >/dev/null 2>&1 || true
    docker pull -q node:22-bookworm-slim >/dev/null
    docker run -d --name capstone-pricing --network devopslings-ha-stack_front --ip 172.29.22.40 \
      node:22-bookworm-slim node -e "$(cat "$F/pricing.js")" >/dev/null
  fi
  docker exec capstone-pricing rm -f /tmp/deny /tmp/price
}

# The tip of main, without a clone.
tip() { git ls-remote "$repo_url" refs/heads/main | cut -f1; }

# Commits whatever is staged in the clone at $1 with message $2, pushes it and
# waits for its pipeline. Prints the jobs; returns 1 if any did not succeed.
ship() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
  git -C "$1" push -q origin HEAD:main
  _jobs=$(wait_run "$(git -C "$1" rev-parse HEAD)" 0)
  printf '%s\n' "$_jobs"
  [ -n "$_jobs" ] && ! printf '%s\n' "$_jobs" | grep -qv ' success$'
}
