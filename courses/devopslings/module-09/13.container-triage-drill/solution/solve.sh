#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The fault is drawn at random, so this is the ladder the lesson teaches, read
# from the running stack: container state, then logs, then the app's own
# readiness answer. The first rung that explains the failure is the fault.
set -euo pipefail
proj=devopslings-container-triage

docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -p "$proj" up -d --build --wait --wait-timeout 90 >/dev/null 2>&1 || true
cid=$(docker compose -p "$proj" ps -aq api | head -1)

# Crash-looping or warming: give it long enough to show which.
for _ in $(seq 1 30); do
  logs=$(docker logs "$cid" 2>&1 || true)
  oom=$(docker inspect -f '{{.State.OOMKilled}}' "$cid")
  case "$logs" in *Error*|*"price cache warm"*) break ;; esac
  [ "$oom" = true ] && break
  sleep 1
done
ready=$(curl -sS -m 5 http://localhost:18094/ready 2>/dev/null || true)

if [ "$oom" = true ]; then
  # 160MB of cache in a 128MB limit; 256MB leaves room for the interpreter.
  sed -i.bak -e 's/mem_limit: .*/mem_limit: 256m/' -e 's/memswap_limit: .*/memswap_limit: 256m/' compose.yaml
  cause="oom: mem_limit 128m is below the 160MB price cache, the kernel OOM-kills api (exit 137) on every start"
  evidence="docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' shows true and a climbing restart count"
  detection="alert when container restarts > 3 in 5 minutes or any oom_kill event"
elif [[ $logs == *FileNotFoundError* ]]; then
  sed -i.bak '/^\*\.json$/d' .dockerignore
  cause="the .dockerignore pattern *.json kept catalog.json out of the build context, so the image lacks it"
  evidence="docker logs shows FileNotFoundError: catalog.json; docker run --rm --entrypoint ls on the image confirms it is missing"
  detection="page when restarts > 3 in 5 minutes, and gate the deploy on a smoke test that must pass within 60 seconds"
elif [[ $logs == *PermissionError* ]]; then
  sed -i.bak 's#^RUN useradd --uid 10001 --create-home app$#RUN useradd --uid 10001 --create-home app \&\& install -d -o app -g app /data#' Dockerfile
  cause="the /data volume is root-owned and the non-root uid 10001 cannot write to it"
  evidence="docker logs shows PermissionError errno 13 on /data/state.json; stat -c %u /data on the volume says 0"
  detection="alert when restarts > 3 in 5 minutes or write errors (EACCES) > 0"
elif [[ $ready == *"quotes unreachable"* ]]; then
  sed -i.bak 's#QUOTES_URL: .*#QUOTES_URL: http://quotes:8000#' compose.yaml
  cause="QUOTES_URL pointed at localhost:18095, the host published port; inside the network it is the service name quotes:8000"
  evidence="curl localhost:18094/ready says quotes unreachable at http://localhost:18095: connection refused"
  detection="alert when the readiness check reports the quotes dependency down for more than 60 seconds"
else
  # Warms up and then goes healthy: the check simply gave up too early.
  awk '{print} /^      retries: /{print "      start_period: 30s"}' compose.yaml > compose.yaml.new
  mv compose.yaml.new compose.yaml
  cause="no start_period on the health check: 3 x 2s of 503 while warming ends before the 12s warm-up does"
  evidence="docker inspect .State.Health log shows 503 warming, then curl /ready answers ready after 12s"
  detection="alert when time to healthy on deploy exceeds 45 seconds"
fi
rm -f compose.yaml.bak Dockerfile.bak .dockerignore.bak

mkdir -p answers
printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" > answers/triage.md
echo "repaired: ${cause%%:*}"
