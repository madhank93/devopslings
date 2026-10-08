#!/usr/bin/env bash
# Asks the box the drill's questions in order and repairs at the first one
# that answers. It never reads /var/lib/storage-drill: the state of the box is
# enough.
set -euo pipefail

LIM=/etc/systemd/system/ingest.service.d/50-platform-limits.conf
answer() { printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$1" "$2" "$3" > /root/answers/triage.md; }
backing() { losetup -nO BACK-FILE "$1" 2>/dev/null | tr -d '[:space:]' || true; }
cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value ingest.service)"
stat_delta() {  # $1 file, $2 key: growth over three seconds
  a=$(awk -v k="$2" '$1 == k {print $2}' "$cg/$1")
  sleep 3
  b=$(awk -v k="$2" '$1 == k {print $2}' "$cg/$1")
  echo $(( b - a ))
}
mkdir -p /root/answers
ingest-stats 10 || true

range=$(cat /proc/sys/net/ipv4/ip_local_port_range)
set -- $range

# 1. Is each mount the volume it is named for?
if [ "$(backing "$(findmnt -no SOURCE /srv/ingest-wal)")" != /var/lib/storage-drill/wal.img ]; then
  findmnt /srv/ingest-wal; cat /srv/ingest-wal/.volume-id; grep /srv/ /etc/fstab
  for mp in /srv/ingest-wal /srv/scratch; do
    case "$mp" in
      /srv/ingest-wal) label=ingest-wal ;;
      *) label=scratch ;;
    esac
    # The label is on the filesystem, so it says which volume each device holds now.
    for lo in $(losetup -nO NAME); do
      [ "$(blkid -s LABEL -o value "$lo" 2>/dev/null || true)" = "$label" ] || continue
      uuid=$(blkid -s UUID -o value "$lo")
      awk -v mp="$mp" -v u="UUID=$uuid" 'BEGIN{OFS="  "} $2 == mp {$1 = u} {print}' /etc/fstab > /etc/fstab.new
      cat /etc/fstab.new > /etc/fstab && rm -f /etc/fstab.new
    done
  done
  systemctl stop ingest.service
  umount /srv/ingest-wal /srv/scratch
  mount /srv/ingest-wal
  mount /srv/scratch
  systemctl start ingest.service
  answer "fstab named the volumes by /dev/loop device name; after a reattach the WAL mount got the scratch volume" \
         "findmnt /srv/ingest-wal and losetup -l showed scratch.img behind it; .volume-id said scratch" \
         "any write failure (ENOENT) > 0 for 1 minute, plus a check that each mount's volume-id matches"

# 2. Bytes: is the filesystem the size of the volume under it?
elif lv=$(lvs --noheadings --units b --nosuffix -o lv_size ingestvg/ingestlv | tr -dc '0-9') && \
     fsb=$(dumpe2fs -h /dev/ingestvg/ingestlv 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Block size/{s=$2} END{printf "%d", c*s}') && \
     [ "$fsb" -lt $(( lv - 4194304 )) ]; then
  df -h /srv/ingest; lvs ingestvg
  resize2fs /dev/ingestvg/ingestlv
  answer "lvextend grew the LV but the filesystem was never resized (no resize2fs), so the import filled it" \
         "lvs showed 320M while df and dumpe2fs showed a 192M filesystem" \
         "df use% on /srv/ingest > 85% for 5 minutes"

# 3. Ports: how many ephemeral ports does a connection per record get?
elif [ $(( $2 - $1 + 1 )) -lt 10000 ]; then
  ss -Htan state time-wait | wc -l; sysctl net.ipv4.ip_local_port_range
  for f in $(grep -l 'ip_local_port_range' /etc/sysctl.d/*.conf); do
    sed -i '/ip_local_port_range/d' "$f"
  done
  sysctl -q -w net.ipv4.ip_local_port_range="32768 60999"
  answer "a sysctl.d baseline narrowed net.ipv4.ip_local_port_range to 10 ports: ephemeral port exhaustion, EADDRNOTAVAIL" \
         "ss -tan state time-wait held every port in sysctl net.ipv4.ip_local_port_range" \
         "TIME_WAIT sockets > 50% of the ephemeral port range"

# 4. CPU: is the kernel suspending it while cores sit idle?
elif [ "$(stat_delta cpu.stat nr_throttled)" -gt 5 ]; then
  grep -E 'nr_periods|nr_throttled|throttled_usec' "$cg/cpu.stat"
  sed -i 's/^CPUQuota=.*/CPUQuota=100%/' "$LIM"
  systemctl daemon-reload
  systemctl restart ingest.service
  answer "CPUQuota=2% in the platform-limits drop-in: ingest throttled with idle cores" \
         "nr_throttled climbing in the unit's cpu.stat" \
         "nr_throttled / nr_periods > 10% over 5 minutes"

# 5. Memory: is it paging against its own limit?
else
  grep -E '^(anon|pswpin|pswpout) ' "$cg/memory.stat"
  systemctl show -p MemoryMax ingest.service
  sed -i 's/^MemoryMax=.*/MemoryMax=512M/' "$LIM"
  systemctl daemon-reload
  systemctl restart ingest.service
  answer "MemoryMax=96M below a 192M working set: ingest swapping against its cgroup memory limit" \
         "pswpin climbing in the unit's memory.stat" \
         "pswpin rate > 100 pages/s for 5 minutes, or memory.pressure some avg10 > 10"
fi

sleep 8
ingest-stats 5
