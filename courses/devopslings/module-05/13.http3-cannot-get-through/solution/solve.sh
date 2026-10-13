#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# HTTP/3 is QUIC, which is UDP. The firewall accepts 443 only for TCP and then
# drops all UDP, so QUIC's first packet never reaches the proxy. Accept
# udp/443 before the blanket UDP drop, in the boot file, and reload it.

sed -i 's/^\([[:space:]]*\)tcp dport { 80, 443 } accept$/&\n\n\1# HTTP\/3 (QUIC)\n\1udp dport 443 accept/' /etc/edge-fw.nft
systemctl reload edge-fw.service
