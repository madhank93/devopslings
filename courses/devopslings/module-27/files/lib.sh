# Shared by module 27's checks and inits: the forge, registry and state
# lookups, and the release check stage 1 grades. Source it; it defines only
# variables and functions.
api="http://127.0.0.1:3000/api/v1"
reg="http://127.0.0.1:5000"
auth="-u devops:devopslings"
repo="devops/checkout"
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# Every lookup below may legitimately find nothing, and each check acts
# on that, so none of them is allowed to fail the script on its own.
jq_ops() { docker exec -i devopslings-ha-ops jq "$@"; }
ops() { docker exec devopslings-ha-ops "$@"; }
sql() {
  docker exec devopslings-ci-stack-db-1 psql -U postgres -d app -tA -F' ' -c "$1" 2>/dev/null || true
}

tasks() { curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null || true; }

# Highest run number on a commit, 0 when it has none.
last_run() {
  tasks | jq_ops -r --arg sha "$1" \
    '[.workflow_runs[]? | select(.head_sha == $sha) | .run_number] | max // 0' 2>/dev/null || echo 0
}

# "job status" lines for the newest pushed run of each workflow on $1
# numbered above $2; empty while there is none. A push starts one run per
# workflow file, and a re-push of the same commit starts newer ones.
run_jobs() {
  tasks | jq_ops -r --arg sha "$1" --argjson after "$2" '
    [.workflow_runs[]? | select(.head_sha == $sha and .run_number > $after and .event != "schedule")]
    | group_by(.workflow_id)
    | map((map(.run_number) | max) as $n | map(select(.run_number == $n)))
    | flatten | .[] | "\(.name) \(.status)"' 2>/dev/null || true
}

# Waits for those runs to finish and prints their jobs. The API lists a job
# only once a runner has picked it up, so a run counts as finished when
# every listed job is, twice in a row 10s apart: time for a job that
# was waiting on the others to appear. Gives up after two minutes if
# no run appears, ten if one never finishes.
wait_run() {
  _i=0
  _jobs=""
  _prev=""
  while [ "$_i" -lt 60 ]; do
    _jobs=$(run_jobs "$1" "$2")
    if [ -z "$_jobs" ] && [ "$_i" -ge 12 ]; then
      break
    fi
    if [ -n "$_jobs" ] && ! printf '%s\n' "$_jobs" | grep -qvE ' (success|failure|cancelled|skipped)$'; then
      [ "$_jobs" = "$_prev" ] && break
      _prev=$_jobs
    else
      _prev=""
    fi
    _i=$((_i + 1))
    sleep 10
  done
  printf '%s' "$_jobs"
}

# The registry tag CI pushed for a commit: the full sha, or any tag that
# contains its first 7 characters.
commit_tag() {
  curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
    | jq_ops -r --arg full "$1" --arg short "${1:0:7}" \
        '.tags // [] | (map(select(. == $full)) + map(select(contains($short)))) | .[0] // empty' 2>/dev/null || true
}

tag_digest() {
  curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/$1" 2>/dev/null \
    | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true
}

# The local image id for a pushed digest, pulling it if the host lacks it.
digest_image_id() {
  docker pull -q "127.0.0.1:5000/checkout@$1" >/dev/null 2>&1 || true
  docker image inspect -f '{{.Id}}' "127.0.0.1:5000/checkout@$1" 2>/dev/null || true
}

# "name id" per docker_container instance in the pipeline's state.
state_containers() {
  sql "select i->'attributes'->>'name', i->'attributes'->>'id'
         from terraform_remote_state.states s,
              jsonb_array_elements(s.data::jsonb->'resources') r,
              jsonb_array_elements(r->'instances') i
        where s.name = 'default' and r->>'mode' = 'managed' and r->>'type' = 'docker_container'"
}

# What the deploy names as its image: docker_image names, and container
# images that are not already a resolved image id.
state_refs() {
  sql "select coalesce(i->'attributes'->>'name', '')
         from terraform_remote_state.states s,
              jsonb_array_elements(s.data::jsonb->'resources') r,
              jsonb_array_elements(r->'instances') i
        where s.name = 'default' and r->>'mode' = 'managed' and r->>'type' = 'docker_image'
       union all
       select i->'attributes'->>'image'
         from terraform_remote_state.states s,
              jsonb_array_elements(s.data::jsonb->'resources') r,
              jsonb_array_elements(r->'instances') i
        where s.name = 'default' and r->>'mode' = 'managed' and r->>'type' = 'docker_container'
          and i->'attributes'->>'image' not like 'sha256:%'"
}

# A server's status on one load balancer: UP, DOWN, ... or empty.
lb_status() {
  ops curl -fsS --max-time 2 "http://$1:8404/stats;csv" 2>/dev/null \
    | awk -F, -v s="$2" '$1 == "app" && $2 == s { print $18 }' || true
}

# 12 requests through www: "<version> <node>", or "ERR" for a failure.
through_www() {
  for _ in $(seq 12); do
    ops curl -fsS --max-time 3 http://www/ 2>/dev/null \
      | jq_ops -r '"\(.version) \(.node)"' 2>/dev/null || echo ERR
  done
}

# The checks on whatever production is running for commit $1. Prints a
# "not yet" and returns 1 on the first that fails.
check_release() {
  _sha=$1
  _jobs=$(wait_run "$_sha" 0)
  if [ -z "$_jobs" ]; then
    echo "not yet: no pipeline ran for ${_sha:0:12}, the tip of main. Production is"
    echo "only ever what the pipeline put there, so the pipeline has to run on every push."
    return 1
  fi
  _bad=$(printf '%s\n' "$_jobs" | grep -v ' success$' | head -1 || true)
  if [ -n "$_bad" ]; then
    echo "not yet: job '${_bad% *}' ended '${_bad##* }' on ${_sha:0:12}, the tip of main."
    echo "Its log is under http://localhost:3000/${repo}/actions."
    return 1
  fi

  _tag=$(commit_tag "$_sha")
  if [ -z "$_tag" ]; then
    echo "not yet: no checkout image in the registry is tagged with commit ${_sha:0:12}."
    echo "The pipeline is green, but a tag like :latest is moved by every build, so it"
    echo "cannot say which build is which; push one named after the commit."
    return 1
  fi
  _want=$(digest_image_id "$(tag_digest "$_tag")")

  _rows=$(state_containers)
  if [ -z "$_rows" ]; then
    echo "not yet: the tofu state in ci-stack's Postgres manages no containers."
    echo "Whatever deployed production did not apply deploy/main.tf through that"
    echo "backend: a container started by hand, or tofu run with some other state,"
    echo "is invisible to the next pipeline run."
    return 1
  fi
  _n=$(printf '%s\n' "$_rows" | grep -c . || true)
  if [ "$_n" -lt 2 ]; then
    echo "not yet: tofu manages ${_n} container. lb1 and lb2 are a pair, but behind"
    echo "them production is still one process; when it stops, www stops."
    return 1
  fi

  _ref=$(state_refs | grep -v '@sha256:' | head -1 || true)
  if [ -n "$_ref" ]; then
    echo "not yet: the deploy names its image as '${_ref}'. A tag can be repointed"
    echo "after the plan is made; deploy the digest the build pushed, image@sha256:..."
    return 1
  fi

  while read -r _name _id; do
    _run=$(docker inspect -f '{{.State.Running}} {{.Image}}' "$_id" 2>/dev/null || true)
    if [ "${_run%% *}" != "true" ]; then
      echo "not yet: state lists ${_name}, but no such container is running. Code,"
      echo "state and the real thing disagree; the next apply would have to rebuild it."
      return 1
    fi
    if [ "${_run#* }" != "$_want" ]; then
      echo "not yet: ${_name} runs image ${_run#* }, but CI built ${_want:-nothing} for"
      echo "${_sha:0:12} (tag ${_tag}). Either the image was built or picked by hand,"
      echo "or no job in the pipeline applies deploy/main.tf, so a new commit never"
      echo "reaches production."
      return 1
    fi
  done <<EOF
$_rows
EOF

  for _lb in lb1 lb2; do
    for _s in shop1 shop2; do
      _st=""
      for _ in $(seq 15); do
        _st=$(lb_status "$_lb" "$_s")
        case "$_st" in UP*) break ;; esac
        sleep 1
      done
      case "$_st" in UP*) ;; *)
        echo "not yet: ${_lb} reports ${_s} as '${_st:-missing}'. It health-checks"
        echo "172.29.22.3${_s#shop}:8080/health; a replica has to be at that address."
        return 1 ;;
      esac
    done
  done
  return 0
}

# capstone_event <stage> <event> [detail] appends one line,
# "<RFC3339 UTC>\t<stage>\t<event>\t<detail>", to /var/lib/capstone/events.log
# in devopslings-ha-ops: the timeline later stages are graded against. It is
# on a named volume, so it lasts exactly as long as the stacks' other state.
# CAPSTONE_AT sets the time, for an event noticed after it happened.
capstone_event() {
  printf '%s\t%s\t%s\t%s\n' "${CAPSTONE_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$1" "$2" "${3:-}" \
    | docker exec -i devopslings-ha-ops sh -c 'mkdir -p /var/lib/capstone && cat >> /var/lib/capstone/events.log'
}

# The last event a stage recorded, or empty.
capstone_last() {
  docker exec devopslings-ha-ops sh -c 'cat /var/lib/capstone/events.log 2>/dev/null' \
    | awk -F'\t' -v s="$1" '$2 == s { e = $3 } END { print e }' || true
}
