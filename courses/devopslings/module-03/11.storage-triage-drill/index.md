---
kind: lesson
title: "ingest is slow, some writes fail, and every graph has an excuse"
description: |
  The ingest service's p99 has degraded and some of its writes fail. That is
  the whole ticket, every time — because the fault is drawn at random from
  five, each a different layer under one service: a CPU quota, a memory limit
  it pages against, a volume that grew without its filesystem, a mount that
  came back as the wrong disk, a port range a baseline narrowed. The drill is
  the order you ask the kernel questions in.
name: storage-triage-drill
slug: storage-triage-drill
createdAt: "2026-10-07"
timingSensitive: true

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 420
    run: |
      set -e
      D=/var/lib/storage-drill
      LIM=/etc/systemd/system/ingest.service.d/50-platform-limits.conf

      # ---- clean slate -------------------------------------------------
      systemctl stop ingest.service ingest-replica.service catalog-warm.service 2>/dev/null || true
      systemctl reset-failed ingest.service ingest-replica.service catalog-warm.service 2>/dev/null || true
      for u in ingest ingest-replica catalog-warm; do
        rm -rf "/etc/systemd/system/$u.service.d" "/etc/systemd/system.control/$u.service.d" \
               "/run/systemd/system.control/$u.service.d"
      done
      for mp in /srv/scratch /srv/ingest-wal /srv/ingest; do
        if mountpoint -q "$mp"; then
          fuser -km "$mp" >/dev/null 2>&1 || true
          umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        fi
      done
      # Loop and device-mapper devices belong to the kernel, not the container, so
      # a box that was torn down leaves them attached. Release every one this
      # lesson made, from this box or an earlier one.
      dmsetup remove catalog 2>/dev/null || true
      dmsetup remove ingestvg-ingestlv 2>/dev/null || true
      for l in $(losetup -nO NAME,BACK-FILE 2>/dev/null | awk -v d="$D/" 'index($2, d) == 1 {print $1}'); do
        losetup -d "$l" 2>/dev/null || true
      done
      # Without udev nothing removes the nodes, and vgcreate refuses a stale /dev/ingestvg.
      rm -rf /dev/ingestvg
      rm -rf "$D" /etc/ingest /opt/ingest /var/lib/ingest /root/answers/triage.md \
             /etc/sysctl.d/60-net-baseline.conf
      awk '!($2 == "/srv/ingest" || $2 == "/srv/ingest-wal" || $2 == "/srv/scratch")' /etc/fstab > /etc/fstab.drill
      cat /etc/fstab.drill > /etc/fstab && rm -f /etc/fstab.drill
      # net.* is per network namespace, so these belong to the box alone.
      sysctl -q -w net.ipv4.ip_local_port_range="32768 60999"
      sysctl -q -w net.ipv4.tcp_tw_reuse=2

      id ingest >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ingest
      install -d "$D" /etc/ingest /opt/ingest /root/answers /srv/ingest /srv/ingest-wal /srv/scratch
      install -d -o ingest -g ingest /var/lib/ingest
      # No udev in a container: loop nodes past the few the image ships must be made.
      for i in $(seq 0 31); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
      done

      # ---- volumes -----------------------------------------------------
      truncate -s 512M "$D/pv.img"
      truncate -s 32M "$D/wal.img" "$D/scratch.img"
      # Real blocks, not a sparse hole: reads of a hole never reach a device.
      dd if=/dev/zero of="$D/catalog.img" bs=1M count=128 status=none

      lo_pv=$(losetup --find --show "$D/pv.img")
      pvcreate -qq "$lo_pv"
      vgcreate -qq ingestvg "$lo_pv"
      # -Zn: without udev the node does not exist yet for lvcreate to zero.
      lvcreate -qq -Zn -L 192M -n ingestlv ingestvg >/dev/null 2>&1
      vgmknodes >/dev/null 2>&1 || true
      mkfs.ext4 -q -F /dev/ingestvg/ingestlv

      lo_w=$(losetup --find --show "$D/wal.img")
      mkfs.ext4 -q -F -L ingest-wal "$lo_w"
      lo_s=$(losetup --find --show "$D/scratch.img")
      mkfs.ext4 -q -F -L scratch "$lo_s"

      lo_c=$(losetup --find --show --direct-io=on "$D/catalog.img")
      dmsetup create catalog --table "0 $(blockdev --getsz "$lo_c") linear $lo_c 0"
      dmsetup mknodes catalog

      printf '%s  %s  ext4  defaults,nofail  0  2\n' \
        /dev/ingestvg/ingestlv /srv/ingest \
        "UUID=$(blkid -s UUID -o value "$lo_w")" /srv/ingest-wal \
        "UUID=$(blkid -s UUID -o value "$lo_s")" /srv/scratch >> /etc/fstab
      mount /srv/ingest
      mount /srv/ingest-wal
      mount /srv/scratch

      echo ingest > /srv/ingest/.volume-id
      echo ingest-wal > /srv/ingest-wal/.volume-id
      echo scratch > /srv/scratch/.volume-id
      install -d -o ingest -g ingest /srv/ingest/records /srv/ingest/backlog /srv/ingest-wal/wal
      install -d -m 1777 /srv/scratch/tmp
      # Yesterday's unprocessed batch: the data the volume exists to hold.
      dd if=/dev/urandom of=/srv/ingest/backlog/batch-1006.bin bs=1M count=64 status=none
      chown ingest:ingest /srv/ingest/backlog/batch-1006.bin

      # ---- the service ---------------------------------------------------
      cat > /etc/ingest/ingest.conf <<'CONF'
      # ingest. Read once, at start.
      records = /srv/ingest/records
      wal = /srv/ingest-wal/wal/ingest.wal
      replica = 10.203.0.10:9100
      deadline_ms = 100
      CONF

      cat > /opt/ingest/ingest.py <<'PY'
      import os
      import random
      import socket
      import time

      CONF = "/etc/ingest/ingest.conf"


      def conf():
          out = {}
          with open(CONF) as fh:
              for line in fh:
                  line = line.strip()
                  if line and not line.startswith("#") and "=" in line:
                      k, v = line.split("=", 1)
                      out[k.strip()] = v.strip()
          return out


      c = conf()
      RECORDS = c["records"]
      WAL = c["wal"]
      host, port = c["replica"].rsplit(":", 1)
      REPLICA = (host, int(port))
      DEADLINE_MS = float(c["deadline_ms"])
      STATS = "/var/lib/ingest/records.log"

      # The dedup index. Every record probes a slice of it in key order, not
      # address order, so the whole index is the working set.
      INDEX_MB = 192
      PROBES = 24000
      index = bytearray(INDEX_MB << 20)
      keys = list(range(0, len(index), 4096))
      random.Random(20261007).shuffle(keys)
      for k in keys:
          index[k] = 1

      SEGMENTS = [os.path.join(RECORDS, "seg-%d.rec" % i) for i in range(8)]
      SEGMENT_BYTES = 1 << 20
      PAD = b"." * 4000


      def checksum(n):
          x = 0
          for i in range(n):
              x = (x * 31 + i) & 0xFFFFFFFF
          return x


      def append(path, data):
          with open(path, "ab") as f:
              f.write(data)


      def forward(data):
          # One connection per record; ingest closes first, so the TIME_WAIT is ours.
          with socket.create_connection(REPLICA, timeout=1) as s:
              s.sendall(data)
              s.shutdown(socket.SHUT_WR)
              if s.recv(16) != b"ok\n":
                  raise OSError("replica did not acknowledge")


      existing = [p for p in SEGMENTS if os.path.exists(p)]
      seg = SEGMENTS.index(max(existing, key=os.path.getmtime)) if existing else 0
      cursor = 0
      seq = 0
      last = ""
      stats = open(STATS, "a", buffering=1)
      while True:
          seq += 1
          t0 = time.monotonic()
          err = ""
          try:
              for k in keys[cursor:cursor + PROBES]:
                  index[k] ^= 1
              cursor = (cursor + PROBES) % len(keys)
              rec = b"%d %d %d " % (seq, time.time_ns(), checksum(150000)) + PAD + b"\n"
              append(SEGMENTS[seg], rec)
              # Rotation needs a successful write, so a full disk never frees itself.
              if os.path.getsize(SEGMENTS[seg]) >= SEGMENT_BYTES:
                  seg = (seg + 1) % len(SEGMENTS)
                  open(SEGMENTS[seg], "wb").close()
              append(WAL, rec[:64] + b"\n")
              if os.path.getsize(WAL) >= 4 * SEGMENT_BYTES:
                  open(WAL, "wb").close()
              forward(rec)
          except OSError as e:
              err = str(e)
          ms = (time.monotonic() - t0) * 1000
          if not err and ms > DEADLINE_MS:
              err = "deadline exceeded (%.0fms)" % DEADLINE_MS
          stats.write("%.3f %s %.1f %s\n" % (time.time(), "fail" if err else "ok", ms, err or "-"))
          if err != last:
              print("ingest: record %d %s" % (seq, ("failed: " + err) if err else "ok again"), flush=True)
              last = err
          time.sleep(0.1)
      PY

      cat > /usr/local/bin/ingest-replica <<'PY'
      #!/usr/bin/env python3
      import socketserver


      class Replica(socketserver.BaseRequestHandler):
          def handle(self):
              while self.request.recv(65536):
                  pass
              self.request.sendall(b"ok\n")


      socketserver.ThreadingTCPServer.allow_reuse_address = True
      socketserver.ThreadingTCPServer(("10.203.0.10", 9100), Replica).serve_forever()
      PY
      chmod 0755 /usr/local/bin/ingest-replica

      cat > /usr/local/bin/ingest-stats <<'PY'
      #!/usr/bin/env python3
      # What ingest measured about itself over the last N seconds (default 30).
      import sys
      import time

      win = float(sys.argv[1]) if len(sys.argv) > 1 else 30
      since = time.time() - win
      lat, why = [], {}
      with open("/var/lib/ingest/records.log") as f:
          for line in f:
              p = line.rstrip("\n").split(" ", 3)
              if len(p) == 4 and float(p[0]) > since:
                  lat.append(float(p[2]))
                  if p[1] == "fail":
                      why[p[3]] = why.get(p[3], 0) + 1
      lat.sort()
      if not lat:
          sys.exit("no records in the last %.0fs" % win)
      pct = lambda q: lat[min(len(lat) - 1, int(len(lat) * q))]
      print("last %.0fs: %d records, %d failed   p50 %.1fms   p99 %.1fms   max %.1fms"
            % (win, len(lat), sum(why.values()), pct(0.5), pct(0.99), lat[-1]))
      for reason, n in sorted(why.items(), key=lambda kv: -kv[1]):
          print("  %5d  %s" % (n, reason))
      PY
      chmod 0755 /usr/local/bin/ingest-stats

      # The red herring: a cache warmer re-reading a volume ingest never touches.
      # Back-to-back fast reads: by far the highest %util on the box, await tiny.
      cat > /usr/local/bin/catalog-warm <<'PY'
      #!/usr/bin/env python3
      import mmap
      import os
      import random

      BS = 1 << 20
      fd = os.open("/dev/mapper/catalog", os.O_RDONLY | os.O_DIRECT)
      blocks = os.lseek(fd, 0, os.SEEK_END) // BS
      buf = mmap.mmap(-1, BS)
      rnd = random.Random()
      while True:
          os.preadv(fd, [buf], rnd.randrange(blocks) * BS)
      PY
      chmod 0755 /usr/local/bin/catalog-warm

      cat > /etc/systemd/system/catalog-warm.service <<'UNIT'
      [Unit]
      Description=catalog cache warmer

      [Service]
      ExecStart=/usr/local/bin/catalog-warm
      CPUQuota=30%
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat > /etc/systemd/system/ingest-replica.service <<'UNIT'
      [Unit]
      Description=ingest replica (stand-in for the downstream copy)

      [Service]
      ExecStartPre=-/usr/sbin/ip addr add 10.203.0.10/32 dev lo
      ExecStart=/usr/local/bin/ingest-replica
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat > /etc/systemd/system/ingest.service <<'UNIT'
      [Unit]
      Description=ingest writer
      After=ingest-replica.service local-fs.target

      [Service]
      User=ingest
      Group=ingest
      ExecStart=/usr/bin/python3 /opt/ingest/ingest.py
      Restart=always
      RestartSec=1

      [Install]
      WantedBy=multi-user.target
      UNIT

      install -d /etc/systemd/system/ingest.service.d
      cat > "$LIM" <<'UNIT'
      # Platform defaults for services on shared boxes.
      [Service]
      CPUQuota=100%
      MemoryAccounting=yes
      MemoryMax=512M
      UNIT

      systemctl daemon-reload
      systemctl enable --now ingest-replica.service catalog-warm.service ingest.service >/dev/null 2>&1

      # n, failures, p99 and the commonest failure for records logged after $1.
      stats_since() {
        python3 - "$1" <<'PY'
      import sys
      since, lat, why = float(sys.argv[1]), [], {}
      try:
          lines = open("/var/lib/ingest/records.log").read().splitlines()
      except OSError:
          lines = []
      for line in lines:
          p = line.split(" ", 3)
          try:
              ts, ms = float(p[0]), float(p[2])
          except (ValueError, IndexError):
              continue
          if ts > since:
              lat.append(ms)
              if p[1] == "fail":
                  why[p[3]] = why.get(p[3], 0) + 1
      lat.sort()
      p99 = lat[min(len(lat) - 1, int(len(lat) * 0.99))] if lat else 0
      top = max(why, key=why.get) if why else "-"
      print(len(lat), sum(why.values()), "%.0f" % p99, top)
      PY
      }

      # Everything works at this point. Prove it before breaking one thing, so a
      # scenario that failed to come up cannot be mistaken for the seeded fault.
      healthy=""
      for _ in 1 2 3 4 5; do
        t=$(date +%s.%N)
        sleep 4
        read -r n f p99 why < <(stats_since "$t")
        if [ "$n" -ge 20 ] && [ "$f" -eq 0 ]; then healthy=yes; break; fi
      done
      if [ -z "$healthy" ]; then
        echo "the scenario did not come up healthy before the fault was seeded"
        echo "last window: $n records, $f failed, p99 ${p99}ms, $why"
        exit 1
      fi

      # ---- seed one fault --------------------------------------------------
      faults="cpu memory resize fstab ports"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      seeded=$(date +%s.%N)
      case "$fault" in
        cpu)
          # A per-service default tightened for a box with more tenants than this one.
          sed -i 's/^CPUQuota=.*/CPUQuota=2%/' "$LIM"
          systemctl daemon-reload
          systemctl restart ingest.service
          ;;
        memory)
          # A limit sized from the service's RSS on a quiet day, below its index.
          sed -i 's/^MemoryMax=.*/MemoryMax=96M/' "$LIM"
          systemctl daemon-reload
          systemctl restart ingest.service
          ;;
        resize)
          # Space was added for tonight's import. The volume grew; its filesystem
          # did not, and the import filled what the filesystem had.
          lvextend -qq -L 320M ingestvg/ingestlv >/dev/null 2>&1
          vgmknodes >/dev/null 2>&1 || true
          dd if=/dev/zero of=/srv/ingest/backlog/import-1007.bin bs=1M status=none 2>/dev/null || true
          chown ingest:ingest /srv/ingest/backlog/import-1007.bin
          sync
          ;;
        fstab)
          # fstab "simplified" to device names that were right on the day, then
          # the volumes were reattached in the other order.
          awk -v w="UUID=$(blkid -s UUID -o value "$lo_w")" -v wd="$lo_w" \
              -v s="UUID=$(blkid -s UUID -o value "$lo_s")" -v sd="$lo_s" \
              'BEGIN{OFS="  "} $1 == w {$1 = wd} $1 == s {$1 = sd} {print}' /etc/fstab > /etc/fstab.drill
          cat /etc/fstab.drill > /etc/fstab && rm -f /etc/fstab.drill
          systemctl stop ingest.service
          umount /srv/ingest-wal /srv/scratch
          losetup -d "$lo_w"
          losetup -d "$lo_s"
          for _ in $(seq 1 20); do
            losetup "$lo_w" "$D/scratch.img" 2>/dev/null && break
            sleep 0.25
          done
          for _ in $(seq 1 20); do
            losetup "$lo_s" "$D/wal.img" 2>/dev/null && break
            sleep 0.25
          done
          mount /srv/ingest-wal
          mount /srv/scratch
          systemctl start ingest.service
          ;;
        ports)
          cat > /etc/sysctl.d/60-net-baseline.conf <<'CONF'
      # acme-netbase 2.1: keep ephemeral ports inside the egress firewall window.
      net.ipv4.ip_local_port_range = 40000 40009
      CONF
          sysctl -q -p /etc/sysctl.d/60-net-baseline.conf
          ;;
      esac

      broke=""
      for _ in $(seq 1 30); do
        sleep 1
        read -r n f p99 why < <(stats_since "$seeded")
        if [ "$f" -ge 3 ]; then broke=yes; break; fi
      done
      if [ -z "$broke" ]; then
        echo "the $fault fault was seeded and ingest still meets its deadline"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # that ingest meets its deadline again, repaired at the cause.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > "$D/state"
      sha256sum /opt/ingest/ingest.py /etc/ingest/ingest.conf \
        /usr/local/bin/catalog-warm /etc/systemd/system/catalog-warm.service \
        /srv/ingest/backlog/*.bin > "$D/sums"
      chmod 600 "$D/state" "$D/sums"

      cat > /root/questions.txt <<'Q'
      The ingest service's p99 has degraded and some of its writes fail.

        ingest-stats                 what ingest measured, last 30 seconds
        /var/lib/ingest/records.log  one line per record: time, ok|fail, ms, why

      Everything worked a moment ago, and exactly one thing was then broken —
      drawn at random from five.

      ingest.service runs /opt/ingest/ingest.py as the user ingest and reads
      /etc/ingest/ingest.conf. Each record probes an in-memory index, is
      appended to /srv/ingest/records (an LVM volume), logged to the WAL on
      /srv/ingest-wal (a volume of its own), and forwarded over TCP to the
      replica at 10.203.0.10:9100. A record that takes over 100ms has failed.

      1. Make ingest meet its deadline again by repairing what was broken,
         where it was broken:

           - the program, its config and its deadline stay as they are
           - ingest keeps a CPU limit and a memory limit
           - everything in /srv/ingest/backlog stays
           - the check restarts ingest and re-applies the sysctl configuration
             before it measures, so a fix has to be in configuration

      2. Write /root/answers/triage.md, three lines:

           cause:     <what was wrong, in a few words>
           evidence:  <the command or counter that proved it>
           detection: <a signal and a threshold that would have paged first>

      Run it again and the fault moves. The drill is the order of the
      questions, not the answer.
      Q

      echo "scenario ready — one fault seeded, ingest missing its deadline"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      D=/var/lib/storage-drill
      digest=$(cat "$D/state" 2>/dev/null || true)
      fault=""
      for cand in cpu memory resize fstab ports; do
        [ "$(printf '%s' "$cand" | sha256sum | awk '{print $1}')" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: $D/state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi

      # ---- left as it was ------------------------------------------------
      bad=$(sha256sum -c --quiet "$D/sums" 2>/dev/null | sed 's/:.*//' || true)
      for path in $bad; do
        case "$path" in
          /srv/ingest/backlog/*)
            echo "not yet: $path is gone or changed. It is data waiting to be"
            echo "         processed, not the problem; deleting it frees space by losing"
            echo "         the thing the volume exists to hold." ;;
          *catalog-warm*)
            echo "not yet: $path has changed. catalog-warm was never the fault;"
            echo "         put it back as it was." ;;
          *)
            echo "not yet: $path has changed. Nothing seeded was in the program or"
            echo "         its config — and a longer deadline only stops it being reported." ;;
        esac
        exit 1
      done
      if [ "$(systemctl show -p User --value ingest.service)" != ingest ] || \
         ! systemctl show -p ExecStart --value ingest.service | grep -q '/opt/ingest/ingest\.py'; then
        echo "not yet: ingest.service must run /opt/ingest/ingest.py as the user ingest."
        exit 1
      fi
      if [ "$(systemctl show -p CPUQuotaPerSecUSec --value ingest.service)" = infinity ] || \
         [ "$(systemctl show -p MemoryMax --value ingest.service)" = infinity ]; then
        echo "not yet: ingest.service has no CPU limit or no memory limit any more."
        echo "         The box is shared; a limit that is wrong gets a better number,"
        echo "         not deleted."
        exit 1
      fi
      if systemctl show -p DropInPaths --value ingest.service | grep -q '/run/'; then
        echo "not yet: part of ingest's configuration is a runtime drop-in under /run"
        echo "         ($(systemctl show -p DropInPaths --value ingest.service | tr ' ' '\n' | grep /run/ | head -1))."
        echo "         That is set-property --runtime, and the next boot forgets it."
        exit 1
      fi

      # ---- configuration re-applied the way a boot would --------------------
      range_live=$(xargs < /proc/sys/net/ipv4/ip_local_port_range)
      sysctl -q --system --pattern '^net\.ipv4\.ip_local_port_range$' >/dev/null 2>&1 || true
      range_conf=$(xargs < /proc/sys/net/ipv4/ip_local_port_range)
      set -- $range_conf
      span=$(( $2 - $1 + 1 ))
      if [ "$fault" = ports ] && [ "$range_live" != "$range_conf" ] && [ "$span" -lt 10000 ]; then
        echo "not yet: ip_local_port_range was $range_live in the running kernel, and re-applying the"
        echo "         sysctl configuration put it back to $range_conf ($span ports)."
        echo "         sysctl -w changes the running kernel only; the file that set it"
        echo "         still sets it: $(grep -rl 'ip_local_port_range' /etc/sysctl.d /etc/sysctl.conf 2>/dev/null | tr '\n' ' ')"
        exit 1
      fi

      # ---- the symptom, measured after a restart ---------------------------
      ooms() { awk '/^oom_kill /{print $2; f=1} END{if(!f)print 0}' "$cg/memory.events" 2>/dev/null || echo 0; }
      stats_since() {
        python3 - "$1" <<'PY'
      import sys
      since, lat, why = float(sys.argv[1]), [], {}
      try:
          lines = open("/var/lib/ingest/records.log").read().splitlines()
      except OSError:
          lines = []
      for line in lines:
          p = line.split(" ", 3)
          try:
              ts, ms = float(p[0]), float(p[2])
          except (ValueError, IndexError):
              continue
          if ts > since:
              lat.append(ms)
              if p[1] == "fail":
                  why[p[3]] = why.get(p[3], 0) + 1
      lat.sort()
      p99 = lat[min(len(lat) - 1, int(len(lat) * 0.99))] if lat else 0
      top = max(why, key=why.get) if why else "-"
      print(len(lat), sum(why.values()), "%.0f" % p99, top)
      PY
      }

      systemctl reset-failed ingest.service 2>/dev/null || true
      if ! systemctl restart ingest.service 2>/dev/null; then
        echo "not yet: ingest.service did not restart:"
        journalctl -u ingest.service -o cat -n 3 --no-pager 2>/dev/null | sed 's/^/         /'
        exit 1
      fi
      cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value ingest.service)"
      k0=$(ooms)
      r0=$(systemctl show -p NRestarts --value ingest.service)
      started=$(date +%s.%N)
      for _ in $(seq 1 30); do
        sleep 1
        read -r n f p99 why < <(stats_since "$started")
        [ "$n" -gt 0 ] && break
      done
      w=$(date +%s.%N)
      sleep 12
      read -r n f p99 why < <(stats_since "$w")
      k1=$(ooms)
      r1=$(systemctl show -p NRestarts --value ingest.service)
      if [ "$k1" -gt "$k0" ] || [ "${r1:-0}" -gt "${r0:-0}" ]; then
        if [ "$k1" -gt "$k0" ] || [ "$(systemctl show -p Result --value ingest.service)" = oom-kill ] || \
           journalctl -u ingest.service --since "@${started%.*}" -o cat --no-pager 2>/dev/null | grep -q 'OOM killer'; then
          echo "not yet: ingest was OOM-killed while the check watched. Taking swap away"
          echo "         from a working set that does not fit its limit does not make it"
          echo "         fit; it only turns slow into dead."
        else
          echo "not yet: ingest died and was restarted $(( ${r1:-0} - ${r0:-0} )) times while the"
          echo "         check watched. journalctl -u ingest says how."
        fi
        exit 1
      fi
      if [ "$n" -lt 60 ] || [ $(( f * 100 )) -gt "$n" ]; then
        echo "not yet: with ingest restarted, it logged $n records in 12s; $f failed,"
        echo "         p99 ${p99}ms against a 100ms deadline."
        [ "$f" -gt 0 ] && echo "         commonest failure: $why"
        echo "         ingest-stats shows the same thing live. The reason narrows it;"
        echo "         it does not finish it."
        exit 1
      fi

      # ---- repaired at the cause -----------------------------------------
      backing() { losetup -nO BACK-FILE "$1" 2>/dev/null | tr -d '[:space:]' || true; }
      for pair in "/srv/ingest-wal wal" "/srv/scratch scratch"; do
        set -- $pair
        got=$(backing "$(findmnt -no SOURCE "$1" 2>/dev/null || true)")
        if [ "$got" != "$D/$2.img" ]; then
          echo "not yet: $1 holds ${got:-nothing}, not $D/$2.img."
          echo "         Making the path work on the wrong volume leaves the right one"
          echo "         unmounted; $(cat "$1/.volume-id" 2>/dev/null || echo '?') is what is there now."
          exit 1
        fi
      done

      case "$fault" in
        resize)
          lv=$(lvs --noheadings --units b --nosuffix -o lv_size ingestvg/ingestlv 2>/dev/null | tr -dc '0-9')
          fsb=$(dumpe2fs -h /dev/ingestvg/ingestlv 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Block size/{s=$2} END{printf "%d", c*s}')
          if [ "${fsb:-0}" -lt $(( ${lv:-0} - 4194304 )) ]; then
            echo "not yet: the filesystem on /srv/ingest is $(( fsb / 1048576 ))M on a"
            echo "         $(( lv / 1048576 ))M logical volume. Writes go through for now;"
            echo "         the space that was added for this is still not in the filesystem."
            exit 1
          fi
          ;;
        fstab)
          for pair in "/srv/ingest-wal wal" "/srv/scratch scratch"; do
            set -- $pair
            src=$(awk -v mp="$1" '$1 !~ /^#/ && $2 == mp {print $1; exit}' /etc/fstab)
            case "$src" in
              '')
                echo "not yet: /etc/fstab has no entry for $1 any more."
                exit 1 ;;
              /dev/*)
                echo "not yet: /etc/fstab mounts $1 from $src — a name the kernel"
                echo "         hands out in attach order. It is right now; it was right"
                echo "         before, too. UUID= or LABEL= names the filesystem itself."
                exit 1 ;;
            esac
            dev=$(findfs "$src" 2>/dev/null || true)
            if [ "$(backing "$dev")" != "$D/$2.img" ]; then
              echo "not yet: the fstab entry for $1 ($src) resolves to ${dev:-nothing},"
              echo "         which is not the $2 volume."
              exit 1
            fi
          done
          ;;
        ports)
          if [ "$span" -lt 10000 ]; then
            echo "not yet: ip_local_port_range is $range_conf after the configuration"
            echo "         was re-applied: $span ephemeral ports for one connection per record."
            if [ "$(cat /proc/sys/net/ipv4/tcp_tw_reuse)" = 1 ]; then
              echo "         tcp_tw_reuse=1 lets connect() take ports still in TIME_WAIT,"
              echo "         which hides the exhaustion rather than ending it."
            fi
            exit 1
          fi
          ;;
      esac

      # ---- the red herring ----------------------------------------------
      if ! systemctl is-active --quiet catalog-warm.service || \
         [ -n "$(systemctl show -p DropInPaths --value catalog-warm.service)" ] || \
         ! dmsetup info catalog >/dev/null 2>&1; then
        echo "not yet: catalog-warm.service is stopped or changed, or its volume is gone."
        echo "         It reads a volume ingest never touches. A high %util with an"
        echo "         await well under a millisecond is a device that is busy, not one"
        echo "         that is saturated. Put it back as it was."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: /root/answers/triage.md is missing or empty. Three lines:"
        echo "         cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      case "$fault" in
        cpu)
          what="the platform-limits drop-in set CPUQuota=2%, so ingest was throttled with idle cores"
          c_re='\b(throttl(e|ed|es|ing)|cpu ?quota|cpu\.max|cfs (quota|bandwidth))\b'
          e_re='\b(nr_throttled|throttled_usec|cpu\.stat)\b'
          e_say="nr_throttled (or throttled_usec) climbing in the unit's cpu.stat"
          d_re='\b(nr_throttled|throttled_usec|throttl(e|ed|ing)|cpu\.stat)\b'
          d_say="throttled periods as a share of periods, from cpu.stat" ;;
        memory)
          what="the platform-limits drop-in set MemoryMax=96M under a 192M index, so ingest paged"
          c_re='\b(memorymax|memory\.max|memory limit|swap(ping|ped)?|pag(ing|ed)|page-?ins?|reclaim|thrash(ing)?)\b'
          e_re='\b(pswpin|pswpout|pgmajfault|memory\.stat|memory\.events|memory\.pressure|workingset_refault_anon)\b'
          e_say="pswpin climbing in the unit's memory.stat"
          d_re='\b(pswpin|pgmajfault|swap(-?ins?)?|memory\.pressure|psi|page-?ins?|major faults?|refaults?)\b'
          d_say="swap-ins per second (pswpin) or memory pressure (memory.pressure)" ;;
        resize)
          what="the LV was extended to 320M and the filesystem left at 192M, then the import filled it"
          c_re='\b(resize2fs|resiz(e|ed|ing)|lvextend(ed)?|never (grown|grew)|not (grown|extended))\b'
          e_re='\b(lvs|lvdisplay|vgs|dumpe2fs|tune2fs|lsblk|blockdev)\b'
          e_say="lvs (320M) against df or dumpe2fs (192M) for the same volume"
          d_re='\b(df|disk|space|use%?|usage|full|filesystem|bytes|capacity)\b'
          d_say="filesystem use (df), percent full" ;;
        fstab)
          what="fstab named the WAL and scratch volumes by /dev/loop number, and they were reattached swapped"
          c_re='\b(fstab|device (names?|paths?)|loop ?(numbers?|devices?)|/dev/loop[0-9]*|uuid|label|renumber(ed|ing)?|reattach(ed)?|swapped)\b'
          e_re='\b(findmnt|lsblk|blkid|losetup|volume-id|mount|/proc/mounts)\b'
          e_say="findmnt or losetup showing what is behind /srv/ingest-wal, or its .volume-id"
          d_re='\b(enoent|errors?|failures?|failed|fail rate|write errors?|mounts?|volume-id|findmnt|wal)\b'
          d_say="write failures, or a check that each mount holds the volume it names" ;;
        ports)
          what="a baseline sysctl drop-in narrowed ip_local_port_range to 10 ports, all in TIME_WAIT"
          c_re='\b(ip_local_port_range|port range|ephemeral|ports? exhaust(ed|ion)|eaddrnotavail|time.?wait|sysctl)\b'
          e_re='\b(ss|netstat|ip_local_port_range|time.?wait|eaddrnotavail|sysctl)\b'
          e_say="ss -tan state time-wait against sysctl net.ipv4.ip_local_port_range"
          d_re='\b(time.?wait|ephemeral|ports?|eaddrnotavail|connect (errors?|failures?)|sockets?)\b'
          d_say="sockets in TIME_WAIT as a share of the ephemeral range" ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and ingest meets its deadline, so"
        echo "         something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before the first failed write: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '> 20% for 5 minutes', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired at its cause; ingest meets its"
      echo "       deadline after a restart, keeps its limits and its backlog, and"
      echo "       catalog-warm is still warming."
---
