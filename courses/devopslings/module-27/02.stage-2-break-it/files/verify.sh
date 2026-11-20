#!/usr/bin/env bash
# Stage 2's check: the drawn fault's own check, then all of stage 1 on a
# grader commit, then (where a hand repair would survive until a redeploy)
# the fault's check once more on what the pipeline put back.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/common.sh"

fault=$(drawn_fault)
if [ -z "$fault" ]; then
  echo "not yet: scratch/stage-2-break-it/.state does not name a seeded fault. Start the"
  echo "lesson again: the scenario has to seed one before it can be graded."
  exit 1
fi

work=$(mktemp -d)
head_sha=""
pushed=""
denied=""
stopped=""
junk=""
cleanup() {
  [ -z "$denied" ] || docker exec capstone-pricing rm -f /tmp/deny >/dev/null 2>&1 || true
  [ -z "$stopped" ] || docker start "$stopped" >/dev/null 2>&1 || true
  for t in $junk; do
    d=$(tag_digest "$t")
    [ -z "$d" ] || curl -fsS -X DELETE "${reg}/v2/checkout/manifests/${d}" >/dev/null 2>&1 || true
  done
  if [ -n "$pushed" ]; then
    git -C "$work/checkout" push -q --force origin "${head_sha}:main" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

if ! git clone -q "$repo_url" "$work/checkout" 2>/dev/null; then
  echo "not yet: could not clone ${repo}"
  exit 1
fi
cd "$work/checkout"
git config user.email grader@example.invalid
git config user.name grader
head_sha=$(git rev-parse HEAD)

# Whatever was pushed last has to finish deploying before production is graded.
wait_run "$head_sha" 0 >/dev/null

# lbwait <server> <UP|DOWN> <seconds>: both load balancers agree.
lbwait() {
  for _ in $(seq "$3"); do
    case "$(lb_status lb1 "$1")/$(lb_status lb2 "$1")" in "$2"*/"$2"*) return 0 ;; esac
    sleep 1
  done
  return 1
}

check_health() {
  when=$1
  price="$((RANDOM % 90 + 10)).$((RANDOM % 90 + 10))"
  docker exec capstone-pricing sh -c "echo ${price} > /tmp/price; rm -f /tmp/deny"
  for s in shop1 shop2; do
    if ! lbwait "$s" UP 20; then
      st=$(lb_status lb1 "$s")
      echo "not yet: ${when}with pricing answering both replicas, lb1 lists ${s} as '${st:-missing}'."
      if [ -z "$st" ]; then
        echo "${s} is not in lb1's configuration. Taking a replica out of /ha/haproxy.cfg by"
        echo "hand hides this failure until the next one, on one replica fewer."
      else
        echo "/health on ${s} answers: $(ops curl -s --max-time 3 "http://172.29.22.3${s#shop}:8080/health" || true)"
      fi
      return 1
    fi
  done

  priced=0
  body=""
  for _ in $(seq 12); do
    body=$(ops curl -fsS --max-time 3 http://www/ 2>/dev/null || true)
    if [ "$(printf '%s' "$body" | jq_ops -r '.price // empty' 2>/dev/null || true)" = "$price" ]; then
      priced=$((priced + 1))
    fi
  done
  if [ "$priced" -lt 12 ]; then
    echo "not yet: ${when}of 12 orders through www, ${priced} carried the price pricing is quoting"
    echo "(${price}). Every order is priced by pricing; one without its price never asked."
    echo "The last answer: ${body:-none}"
    return 1
  fi

  denied=1
  docker exec capstone-pricing sh -c 'echo 172.29.22.31 > /tmp/deny'
  if ! lbwait shop1 DOWN 10; then
    echo "not yet: ${when}pricing is dropping shop1's connections, so every order"
    echo "shop1 takes fails, and 10 seconds later lb1 still lists it as '$(lb_status lb1 shop1)'."
    echo "shop1 answers / with $(ops curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://172.29.22.31:8080/ || true)," \
         "and /health with $(ops curl -s --max-time 3 http://172.29.22.31:8080/health || true)"
    if [ -n "$when" ]; then
      echo "This passed before the pipeline redeployed your commit, so the repair was made"
      echo "to the running containers and not to the code the pipeline ships."
    fi
    return 1
  fi
  fails=0
  for _ in $(seq 20); do
    ops curl -fsS -o /dev/null --max-time 3 http://www/ 2>/dev/null || fails=$((fails + 1))
  done
  if [ "$fails" -gt 0 ]; then
    echo "not yet: ${when}shop1 is out of rotation, but ${fails} of 20 orders through www failed."
    return 1
  fi
  docker exec capstone-pricing rm -f /tmp/deny
  denied=""
  if ! lbwait shop1 UP 20; then
    echo "not yet: ${when}pricing answers shop1 again, and 20 seconds later lb1 lists it as"
    echo "'$(lb_status lb1 shop1)'. A check reports the replica as it is now, not as it once was."
    return 1
  fi
}

# Runs the repository's ci/drift-check.sh at the tip of main, the way a CI job
# would: on ci-stack's network with the host's Docker socket. Extra docker run
# flags go first. Prints its exit code; its output is in $work/drift.log.
run_drift_check() {
  _rc=0
  docker run --rm -i --network devopslings-ci-net -v /var/run/docker.sock:/var/run/docker.sock \
    "$@" devopslings-ha-stack-ops bash -s >"$work/drift.log" 2>&1 <<EOF || _rc=$?
git clone -q http://forge:3000/${repo}.git /w && cd /w && git checkout -q ${head_sha} || exit 99
exec bash ci/drift-check.sh
EOF
  echo "$_rc"
}
drift_log() {
  { grep -m3 -E 'Plan:|No changes|Error' "$work/drift.log" || tail -n 3 "$work/drift.log"; } \
    | sed 's/\x1b\[[0-9;]*m//g; s/^[│╷╵ ]*//; s/^/  | /' || true
}

check_drift() {
  rows=$(state_containers)
  [ -n "$rows" ] || return 0
  while read -r name id; do
    [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" = true ] && continue
    other=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)
    if [ -n "$other" ]; then
      echo "not yet: a container named ${name} is running, but it is not the one the state"
      echo "describes (state: ${id:0:12}, running: ${other:0:12}). It was started outside"
      echo "tofu, so no plan can see it, and the next apply will collide with it."
    else
      echo "not yet: the state lists ${name} (${id:0:12}), and no such container exists."
      echo "Production is not what the pipeline last applied, and nothing noticed."
    fi
    return 1
  done <<EOF
$rows
EOF

  if [ ! -f ci/drift-check.sh ]; then
    echo "not yet: production matches the state again, but nothing would notice the next"
    echo "time it stops matching: there is no ci/drift-check.sh in the repository."
    return 1
  fi
  r=$(run_drift_check)
  if [ "$r" != 0 ]; then
    echo "not yet: ci/drift-check.sh exited ${r} on production that matches the state; it"
    echo "must exit 0 when there is nothing to find:"
    drift_log
    if grep -q -- '-refresh-only' ci/drift-check.sh; then
      echo "A refresh-only plan reports the docker provider's own normalisation as changes,"
      echo "so it finds drift on a clean deploy. Plan what the deploy would apply instead."
    fi
    return 1
  fi

  victim=$(printf '%s\n' "$rows" | tail -1)
  stopped=${victim#* }
  docker stop -t 1 "$stopped" >/dev/null
  r=$(run_drift_check)
  healed=$(docker inspect -f '{{.State.Running}}' "$stopped" 2>/dev/null || true)
  docker start "$stopped" >/dev/null
  stopped=""
  if [ "$healed" = true ]; then
    echo "not yet: the grader stopped ${victim% *}, and running ci/drift-check.sh started it"
    echo "again. A check only looks: one that repairs whatever it finds also undoes a"
    echo "deliberate change in the middle of an incident, with nobody reviewing it."
    return 1
  fi
  if [ "$r" != 2 ]; then
    echo "not yet: the grader stopped ${victim% *}, and ci/drift-check.sh exited ${r}, not 2:"
    drift_log
    if [ "$r" = 0 ]; then
      if grep -q -- '-refresh=false' ci/drift-check.sh; then
        echo "-refresh=false compares the code with the state only and never looks at the"
        echo "real containers, so a stopped one is invisible to it."
      else
        echo "tofu plan exits 0 whether or not it finds changes, unless asked to say otherwise."
      fi
    fi
    return 1
  fi

  r=$(run_drift_check -e DOCKER_HOST=tcp://127.0.0.1:1)
  if [ "$r" = 0 ] || [ "$r" = 2 ]; then
    echo "not yet: with the Docker daemon unreachable, ci/drift-check.sh exited ${r}. It could"
    echo "not look at anything, so it must exit something other than 0 (no drift) or 2"
    echo "(drift):"
    drift_log
    return 1
  fi

  runs=""
  scheduled=""
  for f in .forgejo/workflows/*.yml .forgejo/workflows/*.yaml; do
    [ -f "$f" ] && grep -q 'drift-check.sh' "$f" || continue
    runs=1
    if grep -Eq '^[[:space:]]*schedule:' "$f" && grep -q 'cron:' "$f"; then scheduled=1; fi
  done
  if [ -z "$runs" ]; then
    echo "not yet: ci/drift-check.sh works, but nothing runs it: no workflow under"
    echo ".forgejo/workflows calls it."
    return 1
  fi
  if [ -z "$scheduled" ]; then
    echo "not yet: the workflow that runs ci/drift-check.sh has no schedule. Drift happens"
    echo "between pushes, so a job that only runs on a push never sees it. Use on: schedule:"
    echo "with a cron line."
    return 1
  fi
}

check_retention() {
  before=$(tag_digest "$(commit_tag "$head_sha")")
  [ -n "$before" ] || return 0

  # Stale images for commits that are not on main, as abandoned branches and
  # failed builds leave them.
  for _ in $(seq 12); do
    t=$(od -An -N20 -tx1 /dev/urandom | tr -d ' \n')
    printf 'FROM busybox:1.37.0\nLABEL grader.stale=%s\n' "$t" \
      | docker build -q -t "127.0.0.1:5000/checkout:${t}" - >/dev/null
    docker push -q "127.0.0.1:5000/checkout:${t}" >/dev/null
    docker rmi "127.0.0.1:5000/checkout:${t}" >/dev/null
    junk="$junk $t"
  done

  sed -i.bak "s/const VERSION = \"[^\"]*\"/const VERSION = \"release-$(date +%s)\"/" src/server.js
  rm -f src/server.js.bak
  git add -A
  git commit -qm "grader: one more release"
  pushed=1
  if ! git push -q origin HEAD:main 2>/dev/null; then
    echo "not yet: could not push the grader's commit to main"
    return 1
  fi
  jobs=$(wait_run "$(git rev-parse HEAD)" 0)
  bad=$(printf '%s\n' "$jobs" | grep -v ' success$' | head -1 || true)
  if [ -z "$jobs" ] || [ -n "$bad" ]; then
    echo "not yet: on the grader's release commit, job '${bad% *}' ended '${bad##* }'."
    return 1
  fi

  tags=$(curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null | jq_ops -r '.tags // [] | .[]' 2>/dev/null || true)
  stale=0
  for t in $junk; do
    printf '%s\n' "$tags" | grep -qx "$t" && stale=$((stale + 1))
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/${before}" || true)
  if [ "$code" != 200 ]; then
    echo "not yet: after one more release, the image production ran just before it is gone"
    echo "from the registry, while ${stale} of the 12 stale images the grader pushed for"
    echo "commits that are not on main are still there. A rollback now would fail the way"
    echo "the one in INCIDENT.txt did: ${before}"
    return 1
  fi
  left=$(printf '%s\n' "$tags" | grep -c . || true)
  if [ "$left" -gt 10 ]; then
    echo "not yet: ${left} tags are left in the registry after a release, ${stale} of them the"
    echo "stale images the grader pushed. The rollback is safe because nothing is cleaned"
    echo "up, which is the full disk the retention job was written to prevent. Keep the"
    echo "releases you might roll back to, and at most ten tags."
    return 1
  fi
}

check_cache() {
  when=$1
  if [ -n "$when" ]; then
    want=$(sed -n 's/^const VERSION = "\([^"]*\)".*/\1/p' src/server.js | head -1)
    got=""
    for _ in $(seq 10); do
      got=$(ops curl -fsS --max-time 3 http://www/ 2>/dev/null | jq_ops -r '.version // empty' 2>/dev/null || true)
      [ "$got" = "$want" ] && break
      sleep 1
    done
    if [ "$got" != "$want" ]; then
      echo "not yet: ${when}www answers version '${got}', and"
      echo "your commit says '${want}': the image was built from another commit's code."
      echo "A cache cleared by hand makes one build honest, not the ones after it."
      return 1
    fi
    return 0
  fi
  if ! grep -q -- '--mount=type=cache' Dockerfile 2>/dev/null; then
    echo "not yet: the Dockerfile no longer keeps anything between builds. Deleting the"
    echo "cache does make every build honest, by giving up the time it saved. Keep it, and"
    echo "make what it hands back follow the source."
    return 1
  fi
}

check_split() {
  when=$1
  others=$(sql "select s.name, string_agg(r->>'type' || '.' || (r->>'name'), ' ')
                  from terraform_remote_state.states s,
                       jsonb_array_elements(s.data::jsonb->'resources') r
                 where s.name <> 'default' and r->>'mode' = 'managed'
                 group by s.name" | head -1)
  if [ -n "$others" ]; then
    echo "not yet: ${when}the workspace '${others%% *}' still manages ${others#* }."
    echo "Two states each believe they own production: whichever applies next destroys"
    echo "what the other made, or collides with it."
    return 1
  fi
  while read -r name id; do
    [ -n "$id" ] || continue
    [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" = true ] || continue
    if ! docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" | grep -qx 'PAYMENTS=disabled'; then
      echo "not yet: ${when}${name} runs without PAYMENTS=disabled. The on-call disabled"
      echo "payments during the incident, and they stay disabled until the payments team"
      echo "says otherwise (INCIDENT.txt, 02:23)."
      if [ -n "$when" ]; then
        echo "It was there before the pipeline replaced the replicas: it lived on the"
        echo "containers, not in what the pipeline deploys."
      fi
      return 1
    fi
  done <<EOF
$(state_containers)
EOF
}

case "$fault" in
  health) check_health "" || exit 1 ;;
  drift) check_drift || exit 1 ;;
  retention) check_retention || exit 1 ;;
  cache) check_cache "" || exit 1 ;;
  split) check_split "" || exit 1 ;;
esac

# The retention check leaves main on its own commit; stage 1 grades the
# student's, so it goes back first.
if [ -n "$pushed" ]; then
  git push -q --force origin "${head_sha}:main"
  pushed=""
fi

if ! out=$(bash "$M/files/stage-1-verify.sh" 2>&1); then
  printf '%s\n' "$out"
  if [ "$fault" = cache ] && printf '%s' "$out" | grep -q 'www still answers'; then
    echo "The image CI built for the grader's commit runs older code than the commit holds."
    echo "A cache cleared by hand makes one build honest, not the ones after it."
  fi
  exit 1
fi

again="after the pipeline redeployed your commit, "
case "$fault" in
  health) check_health "$again" || exit 1 ;;
  split) check_split "$again" || exit 1 ;;
  cache) check_cache "$again" || exit 1 ;;
esac

# Once per draw: when the first fix was committed, then now. The first
# commit after the seed is the earliest moment the record can show.
if [ "$(capstone_last stage-2)" = fault_injected ]; then
  first=$(TZ=UTC git log --reverse --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd \
            "$(cat "$S/.seed" 2>/dev/null)..${head_sha}" 2>/dev/null | head -1 || true)
  [ -z "$first" ] || CAPSTONE_AT=$first capstone_event stage-2 first_detected "$fault"
  capstone_event stage-2 fixed "$fault"
fi

case "$fault" in
  health) echo "PASS: a replica that cannot price an order leaves rotation, and comes back when it can." ;;
  drift) echo "PASS: production matches the state, and a scheduled check finds the next drift without touching it." ;;
  retention) echo "PASS: retention still cleans the registry, and never takes the image a rollback needs." ;;
  cache) echo "PASS: the build cache is kept, and what it hands back follows the source." ;;
  split) echo "PASS: one state owns production again, and the payments flag the on-call set survived it." ;;
esac
echo "Then stage 1 again: the grader's commit went all the way to www with nobody touching it."
