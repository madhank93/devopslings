#!/bin/sh
set -e
# The deploy directory changes every release, so integrity-watching it is noise
# by construction. Remove it; keep the stable system paths under watch. The
# baseline is left exactly as it was — the intrusion has to stay visible.
grep -v '/srv/app' /etc/fim/watch.list > /etc/fim/watch.list.new
mv /etc/fim/watch.list.new /etc/fim/watch.list

cat > /root/answers/fim.md <<'ANS'
tampered_file: /etc/sudoers.d/appdeploy
stopped_watching: /srv/app/current
ANS
