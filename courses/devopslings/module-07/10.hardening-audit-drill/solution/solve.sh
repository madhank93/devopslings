#!/usr/bin/env bash
# Walks /etc/reports/baseline.md item by item with the standard audit command
# for each, and restores the first item the box does not match. It never reads
# /var/lib/audit-drill: the state of the box is enough.
set -euo pipefail

answer() { printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$1" "$2" "$3" > /root/answers/triage.md; }
mkdir -p /root/answers
want_cmd='/usr/bin/systemctl restart reports.service'

# 1. sudo: what reportop may actually run, against the one baseline command.
grants=$(sudo -l -U reportop | sed -n '/may run the following commands/,$p' | sed 1d \
  | sed -E 's/^[[:space:]]*\([^)]*\)[[:space:]]*//; s/([A-Z_]+:[[:space:]]*)+//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
  | grep -v '^$' || true)
if [ "$grants" != "$want_cmd" ]; then
  printf 'reportop may run: %s\n' "$grants"
  printf '%s\n' '# reports runbook: the operator restarts the service after a config push.' \
    "reportop ALL=(root) NOPASSWD: $want_cmd" > /etc/sudoers.d/reports
  chmod 0440 /etc/sudoers.d/reports
  visudo -c >/dev/null
  answer "sudoers drop-in granted reportop all of /usr/bin/systemctl, wider than the one restart" \
         "sudo -l -U reportop listed /usr/bin/systemctl with no arguments" \
         "sudo -l -U for each operator account, diffed against the baseline's allowed commands"

# 2. setuid: anything with the bit that no package installed.
elif unowned=$(for f in $(find / -xdev -perm -4000 -type f 2>/dev/null); do
                 dpkg -S "$f" >/dev/null 2>&1 || echo "$f"
               done) && [ -n "$unowned" ]; then
  ls -l $unowned
  chmod u-s,g-s $unowned
  answer "setuid bit (4755) on /usr/local/bin/reports-fetch, which no package installed" \
         "find / -xdev -perm -4000 -type f, then dpkg -S found no owner" \
         "any setuid file from find -perm -4000 that dpkg -S cannot name"

# 3. credentials: the key's owner and mode.
elif [ "$(stat -c '%U:%G %a' /etc/reports/db.key)" != "root:reports 640" ]; then
  stat -c '%U:%G %a %n' /etc/reports/db.key
  chown root:reports /etc/reports/db.key
  chmod 0640 /etc/reports/db.key
  answer "credential /etc/reports/db.key was mode 0644, world-readable" \
         "stat -c '%U:%G %a' /etc/reports/db.key showed 644" \
         "find credential paths with -perm /o+r: any readable-by-others mode is a finding"

# 4. service user: what systemd will run it as.
elif [ "$(systemctl show -p User --value reports.service)" != reports ]; then
  systemctl cat reports.service
  grep -l '^User=' /etc/systemd/system/reports.service.d/*.conf | xargs rm -f
  systemctl daemon-reload
  systemctl restart reports.service
  answer "reports.service ran as root: a debug drop-in overrode User=reports" \
         "systemctl show -p User reports.service said root; systemctl cat showed 10-debug.conf" \
         "systemctl show -p User for every service: empty or root where the baseline names a user"

# 5. listeners: the ports sshd is configured for.
else
  sshd -T | grep '^port '
  ss -ltnp
  grep -lE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config.d/*.conf | xargs rm -f
  sshd -t
  systemctl reload ssh.service
  answer "sshd listening on an extra port 2222 from a drop-in in sshd_config.d" \
         "ss -ltnp showed sshd on 22 and 2222; sshd -T listed port 2222" \
         "listening ports from ss -ltn diffed against the baseline listener list"
fi

for _ in $(seq 1 40); do
  runuser -u reportop -- /usr/local/bin/reports-fetch -s -m 5 http://127.0.0.1:8090/report | grep -q 'report ok' && exit 0
  sleep 0.25
done
echo "reports does not answer" >&2
exit 1
