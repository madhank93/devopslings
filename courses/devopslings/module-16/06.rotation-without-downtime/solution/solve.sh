#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Runs from sandboxes/ci-stack. Writes a rotate.sh with a dual-read window:
# publish new and old together, wait out orders' 10s cache, then change the
# password, then drop the old one from the secret.
set -euo pipefail

cat > ../../scratch/rotation-without-downtime/rotate.sh <<'SH'
#!/usr/bin/env bash
# Rotates the password orders uses for Postgres. Run it from sandboxes/ci-stack.
set -euo pipefail

bao()  { docker compose exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
psql() { docker compose exec -T db psql -U postgres -d app -v ON_ERROR_STOP=1 -qAt "$@"; }

cache=10   # orders' CRED_TTL
old=$(bao kv get -field=password secret/orders/db | tr -d '\r')
new=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')

# 1. Publish both. orders tries the new one, falls back to the old.
bao kv put secret/orders/db username=orders password="$new" previous_password="$old" >/dev/null
# 2. Wait until every cached copy is the pair.
sleep $((cache + 2))
# 3. Switch. The new password now works; the old one is refused.
psql -c "ALTER ROLE orders PASSWORD '$new'"
# 4. Close the window.
bao kv put secret/orders/db username=orders password="$new" >/dev/null

echo "rotated"
SH
