#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Traffic routed through fw1 traverses FORWARD; INPUT only sees packets
# addressed to fw1 itself, which is why the rule never matched. Move the rule
# to FORWARD in the boot file and reload it.

sed -i 's/^-A INPUT -s 10.88.0.0\/24 -p tcp -m tcp --dport 9000 -j DROP$/-A FORWARD -s 10.88.0.0\/24 -d 10.88.1.10\/32 -p tcp -m tcp --dport 9000 -j DROP/' /etc/fw1/rules.v4
systemctl reload fw1-firewall.service
