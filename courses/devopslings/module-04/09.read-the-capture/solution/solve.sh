#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Flow 9301 shows repeated SYN packets from client with increasing intervals,
# but no response from the server, indicating packets are dropped by a firewall
# rather than rejected by the destination host.
# Flow 9302 shows an immediate RST packet from the server, indicating no
# service is listening on that port.
# Flow 9303 shows a successful TCP handshake followed by zero window packets,
# indicating the server's receive buffer is full and its application is not draining it.
cat > /root/answers/capture.md <<'ANS'
flow-9301: verdict=retransmission fault=network
flow-9302: verdict=reset fault=client
flow-9303: verdict=zerowindow fault=server
ANS
