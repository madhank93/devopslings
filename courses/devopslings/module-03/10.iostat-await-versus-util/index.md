---
kind: lesson
title: "the busy disk is fine and the quiet one is the outage"
description: |
  Two volumes, one storage quote, and a utilisation graph that points at the
  wrong one. The volume with roughly twice the utilisation is answering faster
  than anything can ask. The quiet-looking one takes tens of times longer per
  request, at the same queue depth, and is where the audit writes are stuck.
name: iostat-await-versus-util
slug: iostat-await-versus-util
createdAt: "2026-08-10"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 420
    run: |
      install -d /var/lib/iolab /srv/reports /var/lib/devopslings /root/answers

      # Reset anything a previous run left behind.
      for name in catalog audit; do
        dmsetup remove "$name" 2>/dev/null || true
      done
      for img in /var/lib/iolab/catalog.img /var/lib/iolab/audit.img; do
        for l in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do
          losetup -d "$l" 2>/dev/null || true
        done
      done
      rm -f /var/lib/iolab/*.img

      # Two volumes with different jobs. They are device-mapper targets over
      # loop files so the lesson can name them stably — /dev/loopN moves between
      # runs, and a lesson that talks about a device has to be able to say which.
      for name in catalog audit; do
        dd if=/dev/zero of="/var/lib/iolab/$name.img" bs=1M count=1024 status=none
        loop=$(losetup --find --show --direct-io=on "/var/lib/iolab/$name.img")
        sectors=$(blockdev --getsz "$loop")
        dmsetup create "$name" --table "0 $sectors linear $loop 0"
        dmsetup mknodes "$name"
      done

      cat > /usr/local/bin/storage-probe <<'PY'
      #!/usr/bin/env python3
      # Runs both production loads against their volumes and reports what the
      # kernel saw. Re-run it as often as you like; nothing runs between probes.
      import mmap
      import os
      import random
      import subprocess
      import sys
      import threading
      import time

      SECONDS = 20
      SIZE = 1024 * 1024 * 1024

      results = {}

      def catalog_reader():
          # catalog-api: index lookups. Small, random, always more waiting.
          dev, bs, threads = "/dev/mapper/catalog", 131072, 3
          lat = []
          stop = time.time() + SECONDS

          def worker(seed):
              fd = os.open(dev, os.O_RDONLY | os.O_DIRECT)
              buf = mmap.mmap(-1, bs)
              rnd = random.Random(seed)
              while time.time() < stop:
                  off = rnd.randrange(0, SIZE - bs) & ~4095
                  t0 = time.time()
                  os.preadv(fd, [buf], off)
                  lat.append((time.time() - t0) * 1000)
              os.close(fd)

          ts = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
          for t in ts:
              t.start()
          for t in ts:
              t.join()
          results["catalog"] = lat

      def audit_writer():
          # audit-log: every write durable, because that is what an audit log is.
          dev, bs, threads, gap = "/dev/mapper/audit", 65536, 4, 0.004
          lat = []
          stop = time.time() + SECONDS

          def worker(seed):
              fd = os.open(dev, os.O_WRONLY | os.O_DIRECT | os.O_SYNC)
              buf = mmap.mmap(-1, bs)
              buf.write(os.urandom(bs))
              rnd = random.Random(seed)
              while time.time() < stop:
                  off = rnd.randrange(0, SIZE - bs) & ~4095
                  t0 = time.time()
                  os.pwritev(fd, [buf], off)
                  lat.append((time.time() - t0) * 1000)
                  time.sleep(gap)
              os.close(fd)

          ts = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
          for t in ts:
              t.start()
          for t in ts:
              t.join()
          results["audit"] = lat

      loads = [threading.Thread(target=catalog_reader), threading.Thread(target=audit_writer)]
      for t in loads:
          t.start()

      time.sleep(4)
      iostat = subprocess.run(
          ["iostat", "-x", "-y", str(SECONDS - 8), "1"],
          capture_output=True, text=True).stdout

      for t in loads:
          t.join()

      # iostat reports device-mapper volumes by their kernel name (dm-1, dm-2),
      # which says nothing about which volume is which. The names live in sysfs,
      # so resolve them and print the ones this lesson is about.
      names = {}
      for entry in os.listdir("/sys/block"):
          if entry.startswith("dm-"):
              try:
                  with open("/sys/block/%s/dm/name" % entry) as f:
                      names[entry] = f.read().strip()
              except OSError:
                  pass

      lines = ["=== iostat -x, taken while both loads were running ===", ""]
      header = ""
      for line in iostat.splitlines():
          if line.startswith("Device"):
              header = line
              continue
          dev = line.split(" ", 1)[0]
          if names.get(dev) in ("catalog", "audit"):
              if header:
                  lines.append(header)
                  header = ""
              lines.append(line.replace(dev, names[dev].ljust(len(dev)), 1))

      lines += ["", "=== what each service measured, per request ===", ""]
      for name, service in (("catalog", "catalog-api index lookups"), ("audit", "audit-log writes")):
          lat = sorted(results.get(name, []))
          if lat:
              lines.append("%-8s %-28s n=%-8d mean=%.3fms  p99=%.3fms" % (
                  name, service, len(lat), sum(lat) / len(lat), lat[int(len(lat) * 0.99)]))

      report = "\n".join(lines) + "\n"
      with open("/srv/reports/iostat.txt", "w") as f:
          f.write(report)
      sys.stdout.write(report)
      PY
      chmod 0755 /usr/local/bin/storage-probe

      storage-probe >/dev/null 2>&1 || true

      echo audit > /var/lib/devopslings/io.saturated
      echo await > /var/lib/devopslings/io.metric
      echo residency > /var/lib/devopslings/io.utilmeans

      cat > /root/questions.txt <<'Q'
      Two volumes. catalog serves index lookups for catalog-api; audit takes the
      audit log's durable writes. The audit writes have been slow for a week.

      The storage vendor has quoted for replacing the volume that shows the
      higher utilisation, and finance wants a second opinion before signing.

        /srv/reports/iostat.txt     a probe taken with both loads running
        storage-probe               re-run it yourself any time

        /root/answers/saturated     which volume is actually the bottleneck.
                                    One of: catalog, audit

        /root/answers/metric        the column that identifies it. One of:
                                      util          how busy the device looks
                                      await         time per request
                                      iops          requests per second
                                      queue-depth   requests outstanding

        /root/answers/util-means    what %util actually measures. One of:
                                      capacity      how close to its limit it is
                                      residency     how much of the time it had
                                                    at least one request in flight
                                      throughput    how much data it moved
                                      latency       how long requests took
      Q

      echo "scenario ready — probe written to /srv/reports/iostat.txt, re-runnable with storage-probe"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want_sat=$(cat /var/lib/devopslings/io.saturated)
      want_metric=$(cat /var/lib/devopslings/io.metric)
      want_means=$(cat /var/lib/devopslings/io.utilmeans)

      read_answer() {
        if [ ! -s "$1" ]; then
          return 1
        fi
        tr -d '[:space:]' < "$1" | tr 'A-Z' 'a-z'
      }

      if ! sat=$(read_answer /root/answers/saturated); then
        echo "not yet: /root/answers/saturated is missing or empty — catalog or audit"
        exit 1
      fi
      if [ "$sat" != "$want_sat" ]; then
        if [ "$sat" = "catalog" ]; then
          echo "not yet: catalog shows the higher %util, and it is serving its requests"
          echo "         in a fraction of a millisecond. A device that answers instantly"
          echo "         and is asked constantly is busy, not saturated. Look at what a"
          echo "         single request costs on each volume."
        else
          echo "not yet: '$sat' is not one of catalog, audit"
        fi
        exit 1
      fi

      if ! metric=$(read_answer /root/answers/metric); then
        echo "not yet: /root/answers/metric is missing or empty"
        echo "         one of: util, await, iops, queue-depth"
        exit 1
      fi
      if [ "$metric" != "$want_metric" ]; then
        case "$metric" in
          util)
            echo "not yet: util is the column that pointed at the wrong volume — it is"
            echo "         higher on the healthy one. It cannot be the column that"
            echo "         settles the question."
            ;;
          iops)
            echo "not yet: catalog is doing far more requests per second than audit, and"
            echo "         it is the one that is fine. Rate says how much work arrived,"
            echo "         not how hard the device found it."
            ;;
          queue-depth)
            echo "not yet: close, and check the numbers — the queue depths on these two"
            echo "         volumes are about the same. A queue only tells you requests"
            echo "         are waiting; it does not tell you whether waiting is normal"
            echo "         for that device."
            ;;
          *)
            echo "not yet: '$metric' is not one of util, await, iops, queue-depth"
            ;;
        esac
        exit 1
      fi

      if ! means=$(read_answer /root/answers/util-means); then
        echo "not yet: /root/answers/util-means is missing or empty"
        echo "         one of: capacity, residency, throughput, latency"
        exit 1
      fi
      if [ "$means" != "$want_means" ]; then
        case "$means" in
          capacity)
            echo "not yet: that is the assumption this lesson exists to break. If util"
            echo "         measured capacity, 85% would mean 15% left — and catalog would"
            echo "         be nearly out of headroom while answering in 0.03ms."
            ;;
          throughput|latency)
            echo "not yet: util moves without either of those moving. A device handed one"
            echo "         slow request at a time reads 100% while moving almost no data"
            echo "         and one handed a constant stream of instant requests reads the"
            echo "         same. It is a measure of time, not of work or of speed."
            ;;
          *)
            echo "not yet: '$means' is not one of capacity, residency, throughput, latency"
            ;;
        esac
        exit 1
      fi

      if [ ! -s /srv/reports/iostat.txt ]; then
        echo "not yet: /srv/reports/iostat.txt is missing — reset the lesson"
        exit 1
      fi

      echo "PASS — audit named as the saturated volume on await rather than util,"
      echo "       with %util correctly identified as a residency measure. The"
      echo "       quote was for the wrong disk."
---
