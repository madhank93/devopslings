#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# With INPUT at DROP, the replies to web1's own outbound connections arrive as
# inbound packets and match no rule. Accept packets conntrack already ties to a
# connection, first, in the boot file, and reload.

sed -i 's/^-A INPUT -i lo -j ACCEPT$/&\n-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT/' /etc/web1/rules.v4
systemctl reload web1-firewall.service
