#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /etc/systemd/system/stock-feed.service <<'UNIT'
[Unit]
Description=Stock price feed
# After= orders the start. Wants= is what actually pulls stock-cache in when
# the feed is started on its own — After= alone says "if both are starting,
# go second", not "start the other one".
Wants=stock-cache.service
After=stock-cache.service

[Service]
ExecStart=/usr/local/bin/stock-feed
# always, not on-failure: the feed exits 0 on SIGTERM, and on-failure treats a
# clean exit as "it meant to stop".
Restart=always
RestartSec=1

[Install]
# Without an [Install] section there is nothing for `systemctl enable` to
# symlink, and the unit simply never starts at boot.
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable stock-feed.service >/dev/null
systemctl restart stock-feed.service
