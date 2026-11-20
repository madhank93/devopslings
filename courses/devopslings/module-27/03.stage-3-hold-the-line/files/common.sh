# Shared by stage 3's init, fault and check. Source it after files/lib.sh.
M="$DEVOPSLINGS_ROOT/courses/devopslings/module-27"
F="$M/03.stage-3-hold-the-line/files"
S="$DEVOPSLINGS_ROOT/scratch/stage-3-hold-the-line"
repo_url="http://devops:devopslings@127.0.0.1:3000/${repo}.git"
prom="http://127.0.0.1:19090"

# The SLO, as promised to customers. slo.yaml in the repository states it;
# the grader holds it to these numbers whatever the file says.
SLO_AVAILABILITY=99.9
SLO_P99_MS=500

tip() { git ls-remote "$repo_url" refs/heads/main | cut -f1; }
obs() { docker exec "devopslings-obs-stack-$1-1" "${@:2}"; }

# Prometheus on ha-stack's front network, scraping both load balancers'
# exporters, and both targets up.
prom_up() {
  if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
         devopslings-obs-stack-prometheus-1 | grep -q devopslings-ha-stack_front; then
    docker network connect --ip 172.29.22.9 devopslings-ha-stack_front devopslings-obs-stack-prometheus-1
  fi
  obs box sh -c 'grep -q "job_name: capstone-haproxy" /obs/prometheus/prometheus.yml || cat >> /obs/prometheus/prometheus.yml <<YML

  # Module 27: lb1 and lb2, through the exporter built into HAProxy.
  - job_name: capstone-haproxy
    static_configs:
      - targets: ["172.29.22.11:8404", "172.29.22.12:8404"]
YML
obs-reload >/dev/null'
  for _ in $(seq 30); do
    [ "$(promq 'count(up{job="capstone-haproxy"} == 1)')" = 2 ] && return 0
    sleep 1
  done
  echo "Prometheus does not reach lb1 and lb2's exporters: $(promq 'up{job="capstone-haproxy"}')" >&2
  return 1
}

# promq <query> [time]: the first sample's value, or empty.
promq() {
  curl -fsS "${prom}/api/v1/query" --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"} 2>/dev/null \
    | jq_ops -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}
