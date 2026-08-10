#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The queue is capped by `min(the backlog the application requests,
# net.core.somaxconn)`, so raising either one alone changes nothing;
# `somaxconn` is raised first so that the restart picks up a ceiling that is
# already in place; `listen()` takes its backlog once at startup, which is why
# editing the config without restarting the service is a change that appears to
# have been made and has not; and that a larger queue buys time for a busy
# worker rather than making it faster — if the worker never catches up, a deeper
# queue only moves the timeout further out.
sysctl -w net.core.somaxconn=1024 >/dev/null

sed 's/^backlog=4/backlog=512/' /etc/queue.conf > /tmp/queue.conf.new
cat /tmp/queue.conf.new > /etc/queue.conf

systemctl restart queue-app.service
sleep 1
