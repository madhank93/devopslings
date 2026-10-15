#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two age identities, one for the human and one for CI. The file is encrypted
# to both, .sops.yaml records that so the next edit keeps it, and only CI's
# private half goes to the forge. The work happens in the stack's sops
# container, so the host needs nothing but docker.
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
plain="${DEVOPSLINGS_ROOT}/scratch/sops-and-age/secrets.env"

docker compose exec -T sops sh -c 'rm -rf /work/c /work/keys && mkdir -p /work/keys && cat > /work/keys/secrets.env' < "$plain"

ci_key=$(docker compose exec -T sops sh -eu -c '
  cd /work/keys
  age-keygen -o me.txt 2>/dev/null
  age-keygen -o ci.txt 2>/dev/null
  me=$(age-keygen -y me.txt)
  ci=$(age-keygen -y ci.txt)

  git clone -q http://devops:devopslings@forge:3000/devops/checkout.git /work/c
  cd /work/c
  git config user.email devops@example.invalid
  git config user.name devops

  printf "creation_rules:\n  - path_regex: secrets\\.enc\\.env\$\n    age: %s,%s\n" "$me" "$ci" > .sops.yaml
  # Encrypt outside the repo, then move the ciphertext in: the plaintext
  # never exists inside the working tree, so no `git add -A` can catch it.
  sops --disable-version-check --config .sops.yaml -e \
    --filename-override deploy/secrets.enc.env /work/keys/secrets.env > deploy/secrets.enc.env

  git add .sops.yaml deploy/secrets.enc.env
  git commit -qm "encrypted deploy secrets, readable by CI and by me"
  git push -q origin main
  cat /work/keys/ci.txt
')

# Only CI's identity is uploaded; the human key stays where it was made.
payload=$(printf '%s' "$ci_key" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
curl -fsS -u devops:devopslings -X PUT "${api}/repos/devops/checkout/actions/secrets/SOPS_AGE_KEY" \
  -H 'Content-Type: application/json' -d "{\"data\":\"${payload}\"}" >/dev/null
