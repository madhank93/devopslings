#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/bootstrap-node <<'SH'
#!/bin/bash
set -euo pipefail

# Idempotence is not "check whether I ran before". A flag file records that the
# script started, not that the host is in the right state, and it is wrong the
# moment anything is changed by hand or a run is interrupted.
#
# Instead every step asserts the state it wants and does nothing if it already
# holds. Each one is independently safe to re-run, so any prefix of this script
# can be resumed.

# 1. The account.
getent group nodeagent >/dev/null || groupadd nodeagent
getent passwd nodeagent >/dev/null || \
  useradd --system --gid nodeagent --no-create-home nodeagent

# 2. The layout. mkdir -p is already idempotent — that is what -p is for.
mkdir -p /etc/nodeagent /srv/nodeagent /opt/nodeagent-1.4

# 3. Config. Write the whole file from a known template rather than appending
#    lines to whatever was there. Appending is the classic non-idempotent
#    operation: every run adds another copy.
#
#    Writing via a temp file and moving it into place means a reader never sees
#    a half-written config, and an interrupted run leaves the old one intact.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'CONF'
endpoint=https://collector.internal:8443
queue_dir=/srv/nodeagent
CONF
if ! cmp -s "$tmp" /etc/nodeagent/agent.conf 2>/dev/null; then
  mv -- "$tmp" /etc/nodeagent/agent.conf
fi

# 4. The PATH entry, same reasoning.
tmp2=$(mktemp)
printf 'export PATH="$PATH:/opt/nodeagent-1.4/bin"\n' > "$tmp2"
if ! cmp -s "$tmp2" /etc/profile.d/nodeagent.sh 2>/dev/null; then
  mv -- "$tmp2" /etc/profile.d/nodeagent.sh
else
  rm -f "$tmp2"
fi

echo "bootstrap-node: done"
SH
chmod 0755 /usr/local/bin/bootstrap-node
