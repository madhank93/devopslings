#!/bin/sh
set -e
# The stale copy in the working directory shadows /etc. Removing it lets the
# edited file win, which is where the team expects settings to live.
rm -f /opt/greeter/greeter.conf
systemctl restart greeter.service
mkdir -p /root/answers
echo 'path: /opt/greeter/greeter.conf' > /root/answers/config.md
