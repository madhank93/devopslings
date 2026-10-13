#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

sed -i.bak 's/^regions=.*/regions=us-east-1,us-west-2/' status/console.conf
rm -f status/console.conf.bak

cat > remove-capacity.sh <<'SH'
#!/usr/bin/env bash
# Take servers out of service by their position in FLEET_DIR/servers.
# Usage: ./remove-capacity.sh FIRST LAST [FLEET_DIR]
# Refuses, removing nothing, when the request would take more than
# MAX_PER_COMMAND servers out or leave any subsystem below its minimum in
# FLEET_DIR/minimums. Exit 0 means every server in FIRST..LAST is now out.
set -euo pipefail
first=${1:?usage: remove-capacity.sh FIRST LAST [FLEET_DIR]}
last=${2:?usage: remove-capacity.sh FIRST LAST [FLEET_DIR]}
fleet=${3:-fleet}
MAX_PER_COMMAND=2

# Prints one line per reason to refuse; nothing when the request is safe.
reasons=$(awk -v a="$first" -v b="$last" -v max="$MAX_PER_COMMAND" '
  NR == FNR { min[$1] = $2; next }
  { if ($3 == "in") { up[$2]++; if (FNR >= a && FNR <= b) { take[$2]++; n++ } } }
  END {
    if (n > max) printf "would remove %d servers; at most %d per command\n", n, max
    for (s in take) if (up[s] - take[s] < min[s])
      printf "would leave %s at %d in service; minimum is %d\n", s, up[s] - take[s], min[s]
  }' "$fleet/minimums" "$fleet/servers")

if [ -n "$reasons" ]; then
  printf 'REFUSED %s-%s, nothing removed:\n%s\n' "$first" "$last" "$reasons" >&2
  exit 1
fi

awk -v a="$first" -v b="$last" 'NR >= a && NR <= b { $3 = "out" } { print }' \
  "$fleet/servers" > "$fleet/servers.new"
mv "$fleet/servers.new" "$fleet/servers"
echo "removed servers $first-$last"
SH
chmod +x remove-capacity.sh

cat > answers/postmortem.md <<'MD'
# One line per field.

root_cause: A mistyped input to an established playbook command removed far more servers than intended, including a significant portion of the index and placement subsystems, and the tool allowed it because it had no minimum-capacity floor and no limit on how much one command could remove — so careful typing only lowers the rate of a mistake the tool will still execute in full.

status_dependency: The Service Health Dashboard's admin console depended on S3 in us-east-1, so the per-service status could not be updated while the thing it reported on was down; running the console across more than one region means an outage in any single region leaves another to post from.
MD

echo "console.conf, remove-capacity.sh and answers/postmortem.md written"
