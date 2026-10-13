#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# A published port is DNATed in PREROUTING and then forwarded to the
# container, so INPUT never sees it, and in FORWARD its destination port is
# already 80. DOCKER-USER is the chain dockerd evaluates first and never
# rebuilds; filter there on the original destination port, and put the rules in
# the boot file so they come back before dockerd does.

sed -i 's/^-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT$/&\n-A DOCKER-USER -s 10.91.0.50\/32 -j RETURN\n-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 8080 --ctstate NEW -j DROP/' /etc/dock1/rules.v4

systemctl restart dock1-firewall.service
systemctl restart dock1-dockerd.service
