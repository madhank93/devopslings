# Shared helpers for obs-stack task scripts and tools. Source it; every
# function is safe under `set -euo pipefail` and prints nothing on failure
# unless it says otherwise.
PROM=${PROM:-http://prometheus:9090}
AM=${AM:-http://alertmanager:9093}
SINK=${SINK:-http://sink:8080}

# Raw JSON of an instant query.
prom_query() {
  curl -s --max-time 10 "$PROM/api/v1/query" --data-urlencode "query=$1" || echo '{"status":"error","error":"prometheus unreachable"}'
}

# Value of the first series, or empty when the result is empty.
prom_val() {
  prom_query "$1" | jq -r 'if .data.resultType == "scalar" then .data.result[1] else (.data.result[0].value[1] // empty) end' 2>/dev/null || true
}

# Number of series in the result.
prom_count() {
  prom_query "$1" | jq -r '.data.result | length' 2>/dev/null || echo 0
}

# The error Prometheus gave for an expression, or empty when it parsed.
prom_error() {
  prom_query "$1" | jq -r '.error // empty' 2>/dev/null || true
}

# prom_wait EXPR SECONDS — wait until EXPR returns at least one series.
prom_wait() {
  local i
  for i in $(seq 1 "$2"); do
    [ "$(prom_count "$1")" -gt 0 ] && return 0
    sleep 1
  done
  return 1
}

obs_reload() {
  local out rc=0
  if ! out=$(promtool check config /obs/prometheus/prometheus.yml 2>&1); then
    printf 'prometheus config rejected:\n%s\n' "$out"; rc=1
  elif ! out=$(curl -s --max-time 20 -X POST "$PROM/-/reload" -w '\n%{http_code}'); then
    echo "prometheus unreachable"; rc=1
  elif [ "$(printf '%s' "$out" | tail -1)" != 200 ]; then
    printf 'prometheus refused the reload: %s\n' "$(printf '%s' "$out" | head -n -1)"; rc=1
  fi
  if ! out=$(amtool check-config /obs/alertmanager/alertmanager.yml 2>&1); then
    printf 'alertmanager config rejected:\n%s\n' "$out"; rc=1
  elif ! out=$(curl -s --max-time 20 -X POST "$AM/-/reload" -w '\n%{http_code}'); then
    echo "alertmanager unreachable"; rc=1
  elif [ "$(printf '%s' "$out" | tail -1)" != 200 ]; then
    printf 'alertmanager refused the reload: %s\n' "$(printf '%s' "$out" | head -n -1)"; rc=1
  fi
  [ "$rc" = 0 ] && echo "reloaded prometheus and alertmanager"
  return "$rc"
}

# Number of silences currently in force.
obs_active_silences() {
  curl -s --max-time 10 "$AM/api/v2/silences" | jq '[.[] | select(.status.state == "active")] | length' 2>/dev/null || echo 0
}

obs_expire_silences() {
  local id
  for id in $(curl -s --max-time 10 "$AM/api/v2/silences" | jq -r '.[] | select(.status.state != "expired") | .id' 2>/dev/null || true); do
    curl -s --max-time 10 -X DELETE "$AM/api/v2/silence/$id" >/dev/null || true
  done
}

sink_reset() { curl -s --max-time 10 -X POST "$SINK/reset" >/dev/null || true; }

# Every notification the sink has received, as a JSON array of
# {path, at, payload} where payload is Alertmanager's webhook body.
sink_all() { curl -s --max-time 10 "$SINK/notifications" || echo '[]'; }

# sink_firing [JQ-FILTER] — count firing notifications whose payload matches
# the filter (default: all of them).
sink_firing() {
  sink_all | jq "[.[] | select(.payload.status == \"firing\") | select(${1:-true})] | length" 2>/dev/null || echo 0
}

# app_down NAME / app_up NAME / app_restart NAME — steer a supervised app.
app_down() { touch "/obs/run/$1.down"; }
app_up() { rm -f "/obs/run/$1.down"; }
app_restart() { touch "/obs/run/$1.restart"; }

# Newest modification time, in epoch seconds, among the given files.
newest_mtime() { stat -c %Y "$@" 2>/dev/null | sort -n | tail -1 || echo 0; }

# obs_require_loaded — fail with a "not yet" line when Prometheus or
# Alertmanager rejected its config, or when a config or rule file changed
# after the last load. The running config is what gets graded, so this goes
# first in every check that edits one.
obs_require_loaded() {
  local info loaded am
  info=$(curl -s --max-time 10 "$PROM/api/v1/status/runtimeinfo" || true)
  if [ "$(printf '%s' "$info" | jq -r '.data.reloadConfigSuccess' 2>/dev/null || true)" != true ]; then
    echo "not yet: Prometheus rejected the last config it was given and is still running the"
    echo "one before. Run obs-reload to see the error."
    return 1
  fi
  loaded=$(date -d "$(printf '%s' "$info" | jq -r '.data.lastConfigTime' 2>/dev/null || true)" +%s 2>/dev/null || echo 0)
  if [ "$(newest_mtime /obs/prometheus/prometheus.yml /obs/prometheus/rules/*)" -gt "$loaded" ]; then
    echo "not yet: a Prometheus config or rule file changed after Prometheus last loaded it,"
    echo "so it is still running the old version. Run obs-reload."
    return 1
  fi
  am=$(curl -s --max-time 10 "$AM/metrics" || true)
  if ! grep -q '^alertmanager_config_last_reload_successful 1' <<<"$am"; then
    echo "not yet: Alertmanager rejected the last config it was given and is still running"
    echo "the one before. Run obs-reload to see the error."
    return 1
  fi
  loaded=$(awk '/^alertmanager_config_last_reload_success_timestamp_seconds /{printf "%d", $2}' <<<"$am")
  if [ "$(newest_mtime /obs/alertmanager/alertmanager.yml)" -gt "${loaded:-0}" ]; then
    echo "not yet: alertmanager.yml changed after Alertmanager last loaded it, so it is still"
    echo "running the old version. Run obs-reload."
    return 1
  fi
}
