#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The leftovers from earlier runs are not removed by fixing the script.
rm -rf /srv/scratch/build-* 2>/dev/null || true

cat > /usr/local/bin/build-index <<'SH'
#!/bin/bash
set -euo pipefail

work=$(mktemp -d /srv/scratch/build-XXXXXX)

# Register the cleanup immediately after creating the thing it cleans up, so
# there is no window where one exists without the other.
#
# bash runs the EXIT trap when the shell exits for any reason it can observe:
# falling off the end, `exit`, `set -e` aborting, and SIGINT or SIGTERM. So EXIT
# alone covers all three paths this lesson asks about, and adding INT and TERM
# explicitly is only needed if you want to do something different for them.
#
# SIGKILL is the one that cannot be trapped. Nothing can clean up after -9,
# which is why long-lived scratch space wants a reaper as well as a trap.
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

for i in $(seq 1 200); do
  printf 'document %d\n' "$i" > "$work/doc-$i.txt"
done

if [ -e /srv/build/FAIL ]; then
  echo "build-index: corpus is corrupt" >&2
  exit 5
fi
sleep "${BUILD_SECONDS:-0}"

find "$work" -name 'doc-*.txt' | wc -l > /srv/build/index.out

echo "build-index: done"
SH
chmod 0755 /usr/local/bin/build-index
