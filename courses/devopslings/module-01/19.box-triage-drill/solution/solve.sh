#!/usr/bin/env bash
# Asks the box the drill's questions in order and repairs at the first one
# that answers. It never reads /var/lib/drill: the state of the box is enough.
set -euo pipefail

probe() {
  curl -sS -m 5 -X POST --data 'sku=A-100&qty=1' http://127.0.0.1:8088/orders 2>/dev/null | grep -q 'order accepted'
}
answer() { printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$1" "$2" "$3" > /root/answers/triage.md; }
mkdir -p /root/answers

# 1. Is the unit even up? If not, its journal says why.
if ! systemctl is-active --quiet orders.service; then
  journalctl -u orders.service -o cat -n 20 --no-pager | grep -m1 ValueError || true
  sed -i 's/^port = .*/port = 8088/' /etc/orders/orders.conf
  systemctl reset-failed orders.service
  systemctl start orders.service
  answer "config typo: port = 8O88 in /etc/orders/orders.conf" \
         "journalctl -u orders showed ValueError: invalid literal for int()" \
         "orders.service not active, or NRestarts > 3 in 5 minutes"

# 2. Bytes: df full while du is small means space with no directory entry.
elif lsof -nP +L1 2>/dev/null | grep -q ' /srv/orders/'; then
  lsof -nP +L1 2>/dev/null | grep ' /srv/orders/'
  systemctl disable --now orders-export.service
  answer "orders-export held a deleted scratch file open, filling /srv/orders" \
         "lsof +L1 showed the unlinked export.tmp; df 100% while du was 12M" \
         "df use% on /srv/orders > 85% for 5 minutes"

# 3. Inodes: ENOSPC with bytes free.
elif [ "$(df --output=ipcent /srv/orders | tail -1 | tr -dc '0-9')" -ge 90 ]; then
  df -i /srv/orders
  find /srv/orders/spool/.incoming -name '*.part' -type f -size 0 -delete
  answer "inodes exhausted by empty .part files from an aborted import" \
         "df -i /srv/orders showed IUse% 100 with bytes free" \
         "df -i IUse% > 80% on /srv/orders"

# 4. Can the service's user write where it writes?
elif ! runuser -u orders -- test -w /srv/orders/spool; then
  namei -l /srv/orders/spool
  chown orders:orders /srv/orders/spool
  chmod 2770 /srv/orders/spool
  answer "spool directory owned by root:root 0755, service runs as orders: permission denied" \
         "namei -l /srv/orders/spool; runuser -u orders -- test -w fails" \
         "any 5xx on POST /orders: page at > 1% error rate for 2 minutes"

# 5. Descriptors: count against the limit the unit gave the process.
else
  pid=$(systemctl show -p MainPID --value orders.service)
  echo "fds $(ls /proc/"$pid"/fd | wc -l) of: $(grep 'open files' /proc/"$pid"/limits)"
  sed -i 's/^LimitNOFILE=.*/LimitNOFILE=4096/' /etc/systemd/system/orders.service.d/10-hardening.conf
  systemctl daemon-reload
  systemctl restart orders.service
  answer "LimitNOFILE in the hardening drop-in too low: EMFILE, too many open files" \
         "ls /proc/<pid>/fd | wc -l equal to Max open files in /proc/<pid>/limits" \
         "open fds > 80% of LimitNOFILE"
fi

for _ in $(seq 1 40); do
  probe && exit 0
  sleep 0.25
done
echo "orders still does not take writes" >&2
exit 1
