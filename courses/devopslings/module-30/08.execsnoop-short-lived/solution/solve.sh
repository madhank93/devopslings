#!/bin/sh
set -e
# Parameter expansion lower-cases and trims in bash itself, so a pass over the
# inventory starts no processes; only mv and sleep fork, once per pass.
cat > /usr/local/bin/inventory-sync <<'SH'
#!/bin/bash
# Normalises the host inventory into "short fqdn" pairs for the deploy
# tooling, which re-reads hosts.txt every few seconds.
out=/var/lib/inventory/hosts.txt
while :; do
  : > "$out.tmp"
  while read -r h; do
    lower=${h,,}
    echo "${lower%%.*} $lower" >> "$out.tmp"
  done < /etc/inventory/hosts
  mv "$out.tmp" "$out"
  sleep 1
done
SH
systemctl restart inventory-sync.service
mkdir -p /root/answers
echo 'parent: inventory-sync' > /root/answers/forks.md
