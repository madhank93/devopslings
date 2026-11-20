#!/usr/bin/env bash
# Stage 1's check: the release check on the tip of main, a replica killed
# under traffic, then the release check on a grader commit. Later stages run
# it as their own last step.
set -euo pipefail

. "$(dirname "$0")/lib.sh"

work=$(mktemp -d)
head_sha=""
stopped=""
restore() {
  [ -z "$stopped" ] || docker start "$stopped" >/dev/null 2>&1 || true
  if [ -n "$head_sha" ] && [ -d "$work/checkout" ]; then
    _before=$(last_run "$head_sha")
    if git -C "$work/checkout" push -q --force origin "${head_sha}:main" >/dev/null 2>&1; then
      # The redeploy of the student's commit has to finish here, or the
      # next check would grade production halfway back.
      wait_run "$head_sha" "$_before" >/dev/null
    fi
  fi
  rm -rf "$work"
}
trap restore EXIT

if ! git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout" 2>/dev/null; then
  echo "not yet: could not clone ${repo}"
  exit 1
fi
cd "$work/checkout"
git config user.email grader@example.invalid
git config user.name grader
sha=$(git rev-parse HEAD)

check_release "$sha" || exit 1

out=$(through_www)
bad=$(printf '%s\n' "$out" | grep -c '^ERR$' || true)
nodes=$(printf '%s\n' "$out" | grep -v '^ERR$' | awk '{print $2}' | sort -u | grep -c . || true)
if [ "$bad" -gt 0 ] || [ "$nodes" -lt 2 ]; then
  echo "not yet: of 12 requests to www, ${bad} failed and ${nodes} replica(s) answered."
  echo "Both replicas are UP on both load balancers, so look at /ha/lb1/log."
  exit 1
fi

# Either replica can die and www keeps answering.
first=$(state_containers | head -1 | awk '{print $2}')
stopped=$first
docker kill "$first" >/dev/null
sleep 4
out=$(through_www)
docker start "$first" >/dev/null
stopped=""
bad=$(printf '%s\n' "$out" | grep -c '^ERR$' || true)
if [ "$bad" -gt 0 ]; then
  echo "not yet: with one replica killed, ${bad} of 12 requests to www failed."
  exit 1
fi
for _ in $(seq 20); do
  case "$(lb_status lb1 shop1)$(lb_status lb1 shop2)" in UP*UP*) break ;; esac
  sleep 1
done

# The whole path, end to end, on a commit the student never saw.
if ! grep -q 'const VERSION = "' src/server.js; then
  echo "not yet: src/server.js no longer has the VERSION constant the grader changes"
  echo "to prove a new commit reaches production. Leave it in place."
  exit 1
fi
probe="probe-$(date +%s)"
sed -i.bak "s/const VERSION = \"[^\"]*\"/const VERSION = \"${probe}\"/" src/server.js
rm -f src/server.js.bak
git add -A
git commit -qm "grader: release ${probe}"
head_sha=$sha
if ! git push -q origin HEAD:main 2>/dev/null; then
  echo "not yet: could not push the grader's commit to main"
  exit 1
fi
probe_sha=$(git rev-parse HEAD)

if ! check_release "$probe_sha"; then
  echo "That was on the grader's commit ${probe_sha:0:12}, which only changes VERSION."
  echo "Your own commit passed the same checks, so something that got it to production"
  echo "does not happen for a new commit: a step done by hand, or a value pinned to it."
  exit 1
fi
out=$(through_www)
if printf '%s\n' "$out" | grep -qv "^${probe} "; then
  echo "not yet: the pipeline went green on the grader's commit, but www still answers"
  echo "$(printf '%s\n' "$out" | grep -v "^${probe} " | head -1 | awk '{print $1}') instead of ${probe}."
  exit 1
fi

cd /
restore
trap - EXIT
echo "PASS: a commit nobody touched by hand went build, registry, plan, apply, and"
echo "out through both load balancers on two replicas, each of which can die."
