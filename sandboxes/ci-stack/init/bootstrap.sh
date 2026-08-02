#!/bin/sh
# Bring the forge to a known state: one admin, one repo, one runner token.
#
# Lessons assume these exist. Making a student click through a first-run wizard
# before they can start the actual exercise teaches nothing about CI.
#
# Idempotent — `up` runs it again on every start, and it must not fail when the
# state is already there.
set -eu

USER_NAME=devops
USER_PASS=devopslings
USER_MAIL=devops@example.invalid
REPO=checkout

echo "→ bootstrapping forge"

# Forgejo refuses to run as root, and this container needs to be root to write
# to the shared volume. Run the script as root and drop to the `git` user (uid
# 1000, the owner of /data) for the forgejo commands themselves.
fj() { su-exec git forgejo "$@"; }

# forgejo admin commands run against the on-disk state, so this container
# mounts the same volume as the forge itself.
if ! fj admin user list --config /data/gitea/conf/app.ini 2>/dev/null | grep -q "^[0-9]* *${USER_NAME} "; then
  fj admin user create \
    --config /data/gitea/conf/app.ini \
    --username "$USER_NAME" \
    --password "$USER_PASS" \
    --email "$USER_MAIL" \
    --admin --must-change-password=false
  echo "  created user $USER_NAME"
else
  echo "  user $USER_NAME already exists"
fi

# A registration token lets the runner attach itself. Generating a fresh one
# each start is fine: old tokens simply go unused.
#
# `forgejo-cli` does not accept --config the way `forgejo admin` does; it reads
# the location from the environment. Passing --config here does not fail loudly,
# it prints a usage message to stdout, which is exactly the shape of bug that
# ends up written to a token file and rejected later by something else.
TOKEN=$(su-exec git env GITEA_WORK_DIR=/data/gitea GITEA_CUSTOM=/data/gitea \
  forgejo forgejo-cli actions generate-runner-token 2>/dev/null | tr -d '\r\n')

# So check the shape before trusting it. A registration token is a 40-character
# alphanumeric string; anything else is a diagnostic that got captured.
if ! printf '%s' "$TOKEN" | grep -qE '^[A-Za-z0-9]{30,60}$'; then
  echo "  FAILED to generate a runner registration token; got: ${TOKEN:-<empty>}" >&2
  exit 1
fi

mkdir -p /shared
printf '%s' "$TOKEN" > /shared/runner-token
printf '%s' "$USER_PASS" > /shared/user-pass

# Job containers must join the stack's network, not a fresh per-job one, or they
# cannot resolve `forge` and actions/checkout fails to clone the repo that
# triggered the run.
cat > /shared/runner-config.yaml <<'CFG'
log:
  level: info
runner:
  capacity: 2
  timeout: 10m
  fetch_timeout: 10s
container:
  network: devopslings-ci-net
  privileged: false
  # Job steps run `docker build` in later lessons, so the socket comes along.
  valid_volumes:
    - /var/run/docker.sock
CFG

# The runner's own entrypoint. It lives here rather than in the compose file so
# that registration and start are one atomic, re-runnable unit.
cat > /shared/run-runner.sh <<'RUNNER'
#!/bin/sh
set -eu
cd /data
if [ ! -f /data/.runner ]; then
  echo "→ registering runner"
  forgejo-runner register --no-interactive \
    --instance http://forge:3000 \
    --token "$(cat /shared/runner-token)" \
    --name local \
    --labels docker:docker://node:22-bookworm,host:host
fi
echo "→ runner up"
exec forgejo-runner daemon --config /shared/runner-config.yaml
RUNNER
chmod +x /shared/run-runner.sh

# Create the repo the lessons work in, via the API, as the user we just made.
API="http://forge:3000/api/v1"
AUTH="-u ${USER_NAME}:${USER_PASS}"

if ! curl -fsS $AUTH "${API}/repos/${USER_NAME}/${REPO}" >/dev/null 2>&1; then
  curl -fsS $AUTH -X POST "${API}/user/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${REPO}\",\"auto_init\":true,\"default_branch\":\"main\",\"private\":false}" \
    >/dev/null
  echo "  created repo ${USER_NAME}/${REPO}"
else
  echo "  repo ${USER_NAME}/${REPO} already exists"
fi

printf 'http://%s:%s@forge:3000/%s/%s.git' "$USER_NAME" "$USER_PASS" "$USER_NAME" "$REPO" > /shared/repo-url
echo "✓ forge ready — http://localhost:3000  (${USER_NAME} / ${USER_PASS})"
