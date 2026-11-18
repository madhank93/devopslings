# Shared by stage 4's init and check. Source it after files/lib.sh.
M="$DEVOPSLINGS_ROOT/courses/devopslings/module-27"
F="$M/04.stage-4-write-it-up/files"
S="$DEVOPSLINGS_ROOT/scratch/stage-4-write-it-up"

# What a replica runs when the student's own are not there: stage 1's
# service, so the runbook has a production to be run against.
STANDIN='require("node:http").createServer((q, s) => {
  s.setHeader("content-type", "application/json");
  s.end(JSON.stringify(q.url === "/health" ? { ok: true } : { version: "1.0.0", node: require("node:os").hostname() }));
}).listen(8080);'

# Puts production back the way the earlier stages left it: both load
# balancers serving shop1 and shop2, and a replica at each address. Replicas
# that exist are started, never replaced.
ensure_prod() {
  for _n in lb1 lb2; do
    [ "$(docker inspect -f '{{.State.Running}}' "devopslings-ha-$_n" 2>/dev/null)" = true ] \
      || docker start "devopslings-ha-$_n" >/dev/null
    docker exec "devopslings-ha-$_n" lbctl start >/dev/null 2>&1 || true
  done
  if ! ops grep -q '^ *server shop1 ' /ha/haproxy.cfg; then
    docker exec -i devopslings-ha-ops sh -c 'cat > /ha/haproxy.cfg' <<'CFG'
# Shared by lb1 and lb2. Production is two replicas of checkout, at the
# addresses below; the pipeline puts them there.
frontend www
    bind :80
    default_backend app

backend app
    balance roundrobin
    option httpchk GET /health
    server shop1 172.29.22.31:8080 check inter 1s fall 2 rise 2
    server shop2 172.29.22.32:8080 check inter 1s fall 2 rise 2
CFG
  fi
  for _i in 1 2; do
    _c="capstone-shop-$_i"
    [ "$(docker inspect -f '{{.State.Running}}' "$_c" 2>/dev/null)" = true ] && continue
    docker start "$_c" >/dev/null 2>&1 && continue
    docker rm -f "$_c" >/dev/null 2>&1 || true
    docker image inspect node:22-bookworm-slim >/dev/null 2>&1 || docker pull -q node:22-bookworm-slim >/dev/null
    docker run -d --name "$_c" --network devopslings-ha-stack_front --ip "172.29.22.3$_i" \
      node:22-bookworm-slim node -e "$STANDIN" >/dev/null
  done
}

# Empty when production serves: shop1 and shop2 UP on both load balancers
# and www answering. Otherwise one line saying what is not, within $1 seconds.
prod_problem() {
  _p="never checked"
  for _ in $(seq "$1"); do
    _p=""
    for _lb in lb1 lb2; do
      for _s in shop1 shop2; do
        _st=$(lb_status "$_lb" "$_s")
        case "$_st" in UP*) ;; *) _p="${_p:-$_lb reports $_s as '${_st:-nothing}'}" ;; esac
      done
    done
    _code=$(ops curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://www/ 2>/dev/null || true)
    [ "$_code" = 200 ] || _p="${_p:-www answers '${_code:-nothing}'}"
    [ -z "$_p" ] && return 0
    sleep 1
  done
  echo "$_p"
}
