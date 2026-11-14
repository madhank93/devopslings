#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# 1. Lock the whole tree, by hash, at the versions from before the incident.
# 2. Let the sync copy only versions someone has approved, and never delete.
# 3. Write down why the exact pin on ps-tree did not help.
set -euo pipefail

cd /work/wallet
m=/srv/pypi/internal/simple
cat > requirements.txt <<TXT
ps-tree==1.1.0 --hash=sha256:$(sha256sum $m/ps-tree/ps_tree-1.1.0-py3-none-any.whl | cut -d' ' -f1)
event-stream==3.3.5 --hash=sha256:$(sha256sum $m/event-stream/event_stream-3.3.5-py3-none-any.whl | cut -d' ' -f1)
TXT

cat > ci/approved.txt <<'TXT'
ps-tree==1.1.0
event-stream==3.3.4
event-stream==3.3.5
TXT

cat > ci/sync-mirror.sh <<'SH'
#!/bin/sh
# Nightly: copy into the mirror only the releases listed in ci/approved.txt
# (one name==version per line, added by a reviewed change). Nothing is ever
# removed from the mirror, so an upstream unpublish cannot break a build.
set -eu
pub=/srv/pypi/public/simple
mirror=/srv/pypi/internal/simple
approved="$(dirname "$0")/approved.txt"
for f in "$pub"/*/*.whl; do
  [ -e "$f" ] || continue
  project=$(basename "$(dirname "$f")")
  version=$(basename "$f" | cut -d- -f2)
  grep -qxF "$project==$version" "$approved" || continue
  mkdir -p "$mirror/$project"
  cp -n "$f" "$mirror/$project/"
done
SH

sed -i 's/^why_pinning_failed:.*/why_pinning_failed: the pin covered ps-tree only; flatmap-stream came in transitively, through the event-stream>=3.3 range that ps-tree itself declares, so a new event-stream release reached us without any change on our side./' postmortem.txt

# Take the incident's packages back out of the mirror.
rm -f $m/event-stream/event_stream-3.3.6-* $m/flatmap-stream/*.whl

ci/install.sh
