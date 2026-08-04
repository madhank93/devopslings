#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

install -d /root/answers

# When a terminal goes away, the kernel sends SIGHUP to the session leader, and
# the shell forwards it to its jobs. That is the signal to survive.
echo sighup > /root/answers/signal

# setsid puts the job in a brand new session with no controlling terminal, so
# there is no terminal whose loss could ever produce a hangup for it. nohup
# would also pass by setting SIGHUP to SIG_IGN; setsid removes the cause rather
# than ignoring the symptom.
setsid nohup /usr/local/bin/reindex >/var/log/reindex.log 2>&1 < /dev/null &

# Give it a moment to be visible to the check.
sleep 2
