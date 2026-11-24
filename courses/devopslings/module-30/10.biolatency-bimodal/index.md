---
kind: lesson
title: "average await is 3 ms, and 1% of writes take 200 ms"
description: |
  The ledger's writes are durable and mostly fast, and every few seconds a
  handful take a hundred times longer. iostat's average says the disk is fine,
  and an average is exactly what hides this. biolatency shows the latency
  distribution, and the distribution has two humps. Find the second one, the
  writer that makes it, and make it go away without making that writer less
  durable.
name: biolatency-bimodal
slug: biolatency-bimodal
createdAt: "2026-11-23"
timingSensitive: true

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      set -e
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- clean slate ---------------------------------------------------
      systemctl stop ledger-writer.service metrics-compactor.service 2>/dev/null || true
      systemctl reset-failed ledger-writer.service metrics-compactor.service 2>/dev/null || true
      umount /srv/ledger 2>/dev/null || true
      for l in $(losetup -j /var/lib/biolab/ledger.img 2>/dev/null | cut -d: -f1); do
        losetup -d "$l" 2>/dev/null || true
      done
      rm -rf /var/lib/biolab /opt/ledger /opt/metrics-compactor /etc/metrics-compactor.conf \
             /var/log/metrics-compactor.log /root/answers/biolatency.md /var/lib/devopslings/bio.*
      install -d /var/lib/biolab /srv/ledger /opt/ledger /opt/metrics-compactor \
                 /root/answers /var/lib/devopslings

      # ---- the volume ------------------------------------------------------
      # A loop device with direct I/O, so each request reaches the backing disk.
      # barrier=0 keeps cache flushes out of the picture: on a loop file they
      # cost whatever the host's fsync costs, and would form a mode of their own.
      truncate -s 2G /var/lib/biolab/ledger.img
      loop=$(losetup --find --show --direct-io=on /var/lib/biolab/ledger.img)
      mkfs.ext4 -q -F "$loop"
      mount -o barrier=0 "$loop" /srv/ledger
      install -d /srv/ledger/journal /srv/ledger/metrics

      # ---- the service: a 4 KiB durable append every 20 ms -------------------
      cat > /opt/ledger/writer.py <<'PY'
      import os, time
      fd = os.open("/srv/ledger/journal/ledger.log", os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_DSYNC)
      rec = b"x" * 4096
      lat, last = [], time.time()
      while True:
          t = time.time()
          os.write(fd, rec)
          lat.append((time.time() - t) * 1000)
          if time.time() - last >= 30:
              lat.sort()
              print("writes=%d mean=%.2fms p50=%.2fms max=%.1fms" % (
                  len(lat), sum(lat) / len(lat), lat[len(lat) // 2], lat[-1]), flush=True)
              lat, last = [], time.time()
          time.sleep(0.02)
      PY
      cat > /etc/systemd/system/ledger-writer.service <<'U'
      [Unit]
      Description=Ledger journal writer
      RequiresMountsFor=/srv/ledger

      [Service]
      ExecStart=/usr/bin/python3 /opt/ledger/writer.py
      Restart=always
      U

      # ---- the neighbour: a metrics snapshot every 15 s ----------------------
      cat > /opt/metrics-compactor/compactor.py <<'PY'
      import os, time
      conf = {}
      for line in open("/etc/metrics-compactor.conf"):
          line = line.split("#", 1)[0].strip()
          if "=" in line:
              k, v = (s.strip() for s in line.split("=", 1))
              conf[k] = int(v)
      size, every, flush = conf["snapshot_mb"], conf["interval_s"], conf["flush_every_mb"]
      block = os.urandom(1 << 20)
      n = 0
      while True:
          t = time.time()
          tmp = "/srv/ledger/metrics/snapshot.tmp"
          fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
          for i in range(size):
              os.write(fd, block)
              if flush and (i + 1) % flush == 0:
                  os.fsync(fd)
          os.fsync(fd)
          os.close(fd)
          os.rename(tmp, "/srv/ledger/metrics/snapshot")
          n += 1
          with open("/var/log/metrics-compactor.log", "a") as log:
              log.write("snapshot %d: %d MB durable in %.0f ms\n" % (n, size, (time.time() - t) * 1000))
          time.sleep(every)
      PY
      cat > /etc/metrics-compactor.conf <<'C'
      # metrics-compactor: rewrites the metrics snapshot on /srv/ledger.
      snapshot_mb = 128
      interval_s = 15
      # Write this many MB between fsyncs; 0 means one fsync after the whole snapshot.
      flush_every_mb = 0
      C
      cat > /etc/systemd/system/metrics-compactor.service <<'U'
      [Unit]
      Description=Metrics snapshot compactor
      RequiresMountsFor=/srv/ledger

      [Service]
      ExecStart=/usr/bin/python3 /opt/metrics-compactor/compactor.py
      Restart=always
      U
      sha256sum /opt/metrics-compactor/compactor.py /opt/ledger/writer.py > /var/lib/devopslings/bio.sums
      sysctl -n vm.dirty_background_ratio vm.dirty_background_bytes vm.dirty_ratio \
                vm.dirty_bytes vm.dirty_expire_centisecs > /var/lib/devopslings/bio.sysctl
      systemctl daemon-reload
      systemctl start ledger-writer.service metrics-compactor.service

      # ---- record the distribution the student will see ----------------------
      # Two snapshot cycles. The grader compares the student's second mode with
      # this one, and refuses to start a scenario that has no second mode.
      dev=$(basename "$loop")
      timeout -s INT 32 biolatency -d "$dev" > /var/lib/devopslings/bio.before 2>&1 || true
      if ! python3 - /var/lib/devopslings/bio.before > /var/lib/devopslings/bio.truth <<'PY'
      import re, sys
      rows = [tuple(map(int, m.groups())) for m in
              (re.match(r"\s*(\d+)\s*->\s*(\d+)\s*:\s*(\d+)", l) for l in open(sys.argv[1])) if m]
      cnt = [c for _, _, c in rows]
      if not cnt or sum(cnt) < 500:
          sys.exit("biolatency saw %d I/Os on the ledger volume" % sum(cnt))
      main = cnt.index(max(cnt))
      best = None
      for k in range(main + 2, len(rows)):
          v = min(range(main + 1, k), key=lambda i: cnt[i])
          if cnt[v] * 2 < cnt[k] and cnt[k] >= 0.005 * sum(cnt) and (best is None or cnt[k] > cnt[best[0]]):
              best = (k, v)
      if not best:
          sys.exit("no second mode in:\n" + open(sys.argv[1]).read())
      k, v = best
      # peak_lo peak_hi valley_lo slow_from (all usecs)
      print(rows[k][0], rows[k][1], rows[v][0], rows[v + 1][0])
      PY
      then
        echo "scenario did not form: the ledger volume's latency has no second mode on this host." >&2
        cat /var/lib/devopslings/bio.truth /var/lib/devopslings/bio.before >&2
        exit 1
      fi

      cat > /root/questions.txt <<'Q'
      The ledger (ledger-writer.service) appends a durable 4 KiB record to
      /srv/ledger every 20 ms. iostat's average await for the volume is a few
      milliseconds, and the ledger's own log shows a max a hundred times its mean.

      Write /root/answers/biolatency.md:
        second-mode: <the slow mode's range, from biolatency, with its unit>
        cause: <which process makes it, doing what>

      Then make the second mode go away. metrics-compactor must keep writing the
      same snapshot, as often, and as durably.
      Q

      echo "scenario ready — the ledger volume is $loop, mounted at /srv/ledger"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
      ans=/root/answers/biolatency.md
      read -r peak_lo peak_hi valley_lo slow_from < /var/lib/devopslings/bio.truth

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -n 1; }

      # ---- the second mode, by range -----------------------------------------
      mode=$(field second-mode)
      if ! verdict=$(python3 - "$mode" "$peak_lo" "$peak_hi" "$valley_lo" <<'PY'
      import re, sys
      def no(msg):
          print(msg)
          no(1)
      text, plo, phi, vlo = sys.argv[1], *map(int, sys.argv[2:])
      m = re.search(r"([0-9.]+)\s*(?:-|–|->|to)\s*([0-9.]+)\s*(us|usecs?|µs|ms|msecs?)\b", text)
      if not m:
          no("second-mode needs a range and its unit, like '<lo>-<hi> ms', as\n"
                   "         biolatency's buckets print it.")
      scale = 1000 if m.group(3).startswith("ms") else 1
      lo, hi = float(m.group(1)) * scale, float(m.group(2)) * scale
      fmt = lambda us: "%g ms" % (us / 1000) if us >= 1000 else "%d us" % us
      if hi < plo / 2:
          if lo < vlo / 2 and hi < vlo:
              no("second-mode is %s-%s: that is the main hump, where most\n"
                       "         writes land. The second one sits above a gap of near-empty buckets."
                       % (fmt(lo), fmt(hi)))
          no("second-mode is %s-%s, below the slow hump. Read further up the\n"
                   "         histogram, past the near-empty buckets." % (fmt(lo), fmt(hi)))
      if lo > phi * 2:
          no("second-mode is %s-%s, above where the slow writes land." % (fmt(lo), fmt(hi)))
      if lo < vlo / 2:
          no("second-mode starts at %s, inside the main hump. Name the slow mode's\n"
                   "         own range, from where the gap ends." % fmt(lo))
      PY
      ); then
        echo "not yet: ${verdict:-second-mode could not be read}"
        exit 1
      fi

      # ---- the cause ---------------------------------------------------------
      cause=$(field cause)
      if ! printf '%s' "$cause" | grep -Eq '\bmetrics-compactor\b|\bcompactor\b'; then
        if printf '%s' "$cause" | grep -Eq '\b(jbd2|journal|kworker)\b'; then
          echo "not yet: cause says '$cause'. The journal and the flusher threads"
          echo "         carry the I/O; name the process whose writes they are carrying."
        else
          echo "not yet: cause says '$cause'. Name the process whose writes form the"
          echo "         slow mode — biosnoop prints each I/O's process and size."
        fi
        exit 1
      fi
      if ! printf '%s' "$cause" | grep -Eq '\b(fsync\w*|flush\w*|burst\w*|sync\w*|writeback|snapshots?|batch\w*)\b'; then
        echo "not yet: cause names the compactor and not what it does that hurts:"
        echo "         how does its snapshot reach the disk?"
        exit 1
      fi

      # ---- the compactor writes the same, as often, as durably --------------
      if ! sha256sum -c --quiet /var/lib/devopslings/bio.sums >/dev/null 2>&1; then
        echo "not yet: compactor.py or writer.py has been edited. The fix is in how the"
        echo "         compactor is configured; leave both programs as they are."
        exit 1
      fi
      if [ "$(sysctl -n vm.dirty_background_ratio vm.dirty_background_bytes vm.dirty_ratio \
               vm.dirty_bytes vm.dirty_expire_centisecs)" != "$(cat /var/lib/devopslings/bio.sysctl)" ]; then
        echo "not yet: vm.dirty_* has changed. Those sysctls are not namespaced: in this"
        echo "         box they change the Docker host's kernel for every container on it."
        echo "         Put them back, and fix the writer instead."
        exit 1
      fi
      conf() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p" /etc/metrics-compactor.conf | tail -n 1; }
      if [ "$(conf snapshot_mb)" != 128 ]; then
        echo "not yet: snapshot_mb is $(conf snapshot_mb). The snapshot is 128 MB of metrics;"
        echo "         a smaller one is a smaller burst and lost data."
        exit 1
      fi
      if [ "$(conf interval_s)" != 15 ]; then
        echo "not yet: interval_s is $(conf interval_s). Rarer snapshots make rarer bursts, each"
        echo "         as slow as before, and staler metrics."
        exit 1
      fi
      for u in ledger-writer metrics-compactor; do
        systemctl restart "$u.service" 2>/dev/null || true
        if ! systemctl is-active -q "$u.service"; then
          echo "not yet: $u.service is not running:"
          journalctl -u "$u" -n 3 --no-pager 2>/dev/null | sed 's/^/         /' || true
          exit 1
        fi
      done

      # ---- a fresh histogram -------------------------------------------------
      dev=$(basename "$(findmnt -no SOURCE /srv/ledger)")
      before=$(wc -l < /var/log/metrics-compactor.log 2>/dev/null || echo 0)
      out=$(mktemp)
      timeout -s INT 33 biolatency -d "$dev" > "$out" 2>&1 || true
      after=$(wc -l < /var/log/metrics-compactor.log 2>/dev/null || echo 0)
      if [ $((after - before)) -lt 2 ]; then
        echo "not yet: metrics-compactor finished $((after - before)) snapshot(s) in 33 s; it"
        echo "         used to finish two. It must keep up with its interval."
        rm -f "$out"
        exit 1
      fi
      read -r total slow < <(python3 - "$out" "$slow_from" <<'PY'
      import re, sys
      rows = [tuple(map(int, m.groups())) for m in
              (re.match(r"\s*(\d+)\s*->\s*(\d+)\s*:\s*(\d+)", l) for l in open(sys.argv[1])) if m]
      print(sum(c for _, _, c in rows), sum(c for lo, _, c in rows if lo >= int(sys.argv[2])))
      PY
      )
      rm -f "$out"
      if [ "${total:-0}" -lt 500 ]; then
        echo "not yet: biolatency saw only ${total:-0} I/Os on $dev in 33 s; the ledger"
        echo "         writes 50 a second."
        exit 1
      fi
      if [ $((slow * 200)) -gt "$total" ]; then
        echo "not yet: $slow of $total I/Os on $dev still took $((slow_from / 1000)) ms or more."
        echo "         The second mode is still there: something still puts a large burst"
        echo "         in the device's queue at once. biosnoop shows whose."
        exit 1
      fi

      echo "PASS — the slow mode is gone ($slow of $total I/Os at $((slow_from / 1000)) ms or more),"
      echo "       and metrics-compactor still writes 128 MB durably every 15 s."
