#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

install -d /root/answers

# `sysctl --system` prints each file as it reads it. Files across /etc/sysctl.d,
# /usr/lib/sysctl.d and /run/sysctl.d are merged and applied in lexicographic
# order by filename, and the LAST write to a key wins. 99-vendor-net.conf sorts
# after 10-edge-proxy.conf, so it is applied second and its 7200 is what remains.
echo /etc/sysctl.d/99-vendor-net.conf > /root/answers/override

# The vendor file says not to edit it, and a package upgrade would replace it
# anyway. Add a drop-in that sorts after it instead — the same convention every
# other drop-in directory uses.
cat > /etc/sysctl.d/99-zz-edge-proxy.conf <<'CONF'
# Overrides the keepalive in 99-vendor-net.conf. Named to sort last: sysctl
# applies files in lexicographic order and the final write to a key wins.
net.ipv4.tcp_keepalive_time = 120
CONF

# Remove the earlier attempt, which is dead weight: it is applied and then
# overwritten, so leaving it in place suggests the setting is handled when it
# is not.
rm -f /etc/sysctl.d/10-edge-proxy.conf

# Apply it now, the same way a boot would, rather than with `sysctl -w`.
systemctl restart systemd-sysctl.service >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
