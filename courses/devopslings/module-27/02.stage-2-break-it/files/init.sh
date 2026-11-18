#!/usr/bin/env bash
# Stage 2's init: stage 1 working (the student's own, or the reference laid
# down and shipped), then one fault drawn from five and seeded into it.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/common.sh"

mkdir -p "$S"
rm -f "$S/.state" "$S/stage-1.log" "$S/INCIDENT.txt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- what an earlier attempt seeded -------------------------------------
docker rm -f capstone-pricing >/dev/null 2>&1 || true
sql "delete from terraform_remote_state.states where name <> 'default'" >/dev/null
git clone -q "$repo_url" "$work/before"
seeded=""
[ ! -e "$work/before/.forgejo/workflows/retention.yml" ] || seeded=1
! grep -q 'type=cache' "$work/before/Dockerfile" 2>/dev/null || seeded=1
! grep -q '172.29.22.40' "$work/before/src/server.js" 2>/dev/null || seeded=1

# ---- stage 1, working ------------------------------------------------------
if [ -z "$seeded" ] && [ -n "$(state_containers)" ] \
   && bash "$M/files/stage-1-verify.sh" >"$S/stage-1.log" 2>&1; then
  echo "Stage 1 passes, so production is your pipeline and your deploy."
else
  if [ -n "$seeded" ]; then
    echo "checkout still carries a fault from an earlier draw: laying stage 1's reference down."
  else
    echo "Stage 1 does not pass (scratch/stage-2-break-it/stage-1.log says why):"
    echo "laying its reference solution down instead."
  fi
  bash "$M/files/seed.sh" >/dev/null
  bash "$M/files/solve.sh"
  jobs=$(wait_run "$(tip)" 0)
  if [ -z "$jobs" ] || printf '%s\n' "$jobs" | grep -qv ' success$'; then
    echo "stage 1's reference did not ship: ${jobs:-no pipeline ran}"
    exit 1
  fi
fi
echo

# ---- one fault -------------------------------------------------------------
n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
fault=$(echo "$FAULTS" | cut -d' ' -f$(( n % 5 + 1 )))

git clone -q "$repo_url" "$work/checkout"
c="$work/checkout"
git -C "$c" config user.email devops@example.invalid
git -C "$c" config user.name devops
version=$(sed -n 's/^const VERSION = "\([^"]*\)".*/\1/p' "$c/src/server.js" | head -1)

case "$fault" in
  health)
    pricing_up
    sed "s/__VERSION__/${version:-1.0.0}/" "$F/server-priced.js" > "$c/src/server.js"
    ship "$c" "checkout: price every order with the pricing service" >/dev/null
    # This morning, for a few seconds: pricing dropped one replica's connections.
    docker exec capstone-pricing sh -c 'echo 172.29.22.31 > /tmp/deny'
    sleep 4
    seen=$(for _ in $(seq 8); do
             ops curl -s -o /dev/null -w '%{http_code} ' --max-time 3 http://www/ || true
           done)
    stats=$(for lb in lb1 lb2; do echo "$lb: shop1 $(lb_status "$lb" shop1), shop2 $(lb_status "$lb" shop2)"; done)
    docker exec capstone-pricing rm -f /tmp/deny
    cat > "$S/INCIDENT.txt" <<TXT
09:12  checkout error rate 50% for eleven minutes; recovered on its own
09:12  www status codes, eight requests in a row: ${seen}
09:12  load balancers at the time:
$(printf '%s\n' "$stats" | sed 's/^/         /')
09:23  nothing paged, nothing restarted, nothing deployed
TXT
    ;;

  drift)
    victim=$(state_containers | sed -n 2p)
    docker rm -f "${victim#* }" >/dev/null
    sleep 4
    cat > "$S/INCIDENT.txt" <<TXT
overnight  nothing deployed; the last pipeline run is green
07:40      lb1 reports: shop1 $(lb_status lb1 shop1), shop2 $(lb_status lb1 shop2)
07:40      nobody was paged; a customer noticed slow checkouts first
TXT
    ;;

  retention)
    before=$(tag_digest "$(commit_tag "$(tip)")")
    cp "$F/retention.yml" "$c/.forgejo/workflows/retention.yml"
    sed -i.bak 's/^const VERSION = "[^"]*"/const VERSION = "1.1.0"/' "$c/src/server.js"
    rm -f "$c/src/server.js.bak"
    ship "$c" "release 1.1.0, and keep the registry from filling its disk" >/dev/null
    why=$(curl -sS -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/${before}" 2>&1 | head -c 300 || true)
    cat > "$S/INCIDENT.txt" <<TXT
10:02  1.1.0 deployed by the pipeline
10:15  1.1.0 double-charges a card when a retry lands; decision: roll back
10:16  rollback: redeploy what ran before 1.1.0, 127.0.0.1:5000/checkout@${before}
10:16  rollback FAILED. The registry answered:
         ${why}
10:40  fixed forward instead; 25 minutes of double charges
TXT
    ;;

  cache)
    # A cache mount left by an earlier attempt would hold another attempt's
    # build; this one starts empty.
    docker builder prune -f --filter type=exec.cachemount >/dev/null 2>&1 || true
    cp "$F/Dockerfile.cached" "$c/Dockerfile"
    ship "$c" "build: keep the bundle step's output between builds" >/dev/null
    sed -i.bak 's/^const VERSION = "[^"]*"/const VERSION = "1.1.0"/' "$c/src/server.js"
    rm -f "$c/src/server.js.bak"
    ship "$c" "release 1.1.0" >/dev/null
    sleep 3
    serving=$(ops curl -s --max-time 3 http://www/ || true)
    cat > "$S/INCIDENT.txt" <<TXT
14:05  1.1.0 merged; pipeline green, deploy job applied it
14:06  www answers: ${serving}
14:30  QA: none of 1.1.0's changes are live
TXT
    ;;

  split)
    image=$(sql "select i->'attributes'->>'name'
                   from terraform_remote_state.states s,
                        jsonb_array_elements(s.data::jsonb->'resources') r,
                        jsonb_array_elements(r->'instances') i
                  where s.name = 'default' and r->>'type' = 'docker_image'" | head -1)
    for id in $(state_containers | awk '{print $2}'); do docker rm -f "$id" >/dev/null; done
    # The on-call's laptop: its own deploy file, applied to a new workspace.
    { echo "cat > main.tf <<'HCL'"; cat "$F/hotfix.tf"; echo "HCL"
      echo "tofu init -input=false >/dev/null"
      echo "tofu workspace new hotfix >/dev/null"
      echo "tofu apply -auto-approve -input=false -var 'image=${image}' >/dev/null"
    } | docker run --rm -i --network devopslings-ci-net -v /var/run/docker.sock:/var/run/docker.sock \
          -w /tmp devopslings-ha-stack-ops bash -se
    git -C "$c" commit -q --allow-empty -m "retry the deploy"
    git -C "$c" push -q origin HEAD:main
    wait_run "$(git -C "$c" rev-parse HEAD)" 0 >/dev/null
    cat > "$S/INCIDENT.txt" <<'TXT'
02:10  state database failing over; every deploy job fails to take the state lock
02:14  payments provider reports card testing; payments team: disable payments now
02:20  on-call, from a laptop, with the pipeline unable to deploy:
         docker rm -f both replicas
         wrote a deploy file with PAYMENTS=disabled on the containers
         tofu workspace new hotfix && tofu apply, same digest as production
02:23  payments disabled. They stay disabled until the payments team says
       otherwise; nobody else turns them back on.
02:40  state database back
09:00  every push since has failed at deploy; latest: "retry the deploy"
TXT
    ;;
esac

printf '%s' "$fault" | sha256sum | awk '{print $1}' > "$S/.state"

cat <<'Q'
Stage 1 shipped checkout. Since then something has gone wrong in production,
and the notes below are everything anyone wrote down. One fault was drawn at
random from five, in whichever layer it lives: the code, the image build, the
pipeline, the registry, the state or the load balancers.

  scratch/stage-2-break-it/INCIDENT.txt   what was seen
  docker exec devopslings-ha-ops curl -s http://www/
  http://localhost:3000/devops/checkout/actions

Fix the cause, so that a commit nobody touches by hand still reaches www,
and so that the same fault cannot happen again quietly. The check replays
the fault, then ships a grader commit through the whole of stage 1.

Q
cat "$S/INCIDENT.txt"
