---
kind: lesson
title: "the worker that vanishes at 02:00 and leaves no note"
description: |
  report-builder logs "starting", then nothing. No traceback, no error, no exit
  message — because nothing in the process got the chance to write one. The
  record exists, it is just not in the place the application would have put it.
name: oom-killed
slug: oom-killed
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv/reports /root/answers /var/lib/devopslings

      # 20,000 records. Small on disk; expensive if you hold them all at once.
      python3 - <<'PY'
      with open('/srv/reports/orders.tsv', 'w') as f:
          for i in range(1, 20001):
              f.write(f"ORD-{i:06d}\tSKU-{(i*7)%1000:04d}\t{(i%9)+1}\t{((i*13)%50000)/100:.2f}\n")
      PY

      # The builder reads everything into memory, then formats everything into
      # another list, then joins it. Three full copies of the data live at once.
      cat > /usr/local/bin/report-builder <<'SH'
      #!/usr/bin/env python3
      import sys

      print("report-builder: starting", flush=True)

      rows = []
      with open("/srv/reports/orders.tsv") as f:
          for line in f:
              oid, sku, qty, price = line.rstrip("\n").split("\t")
              # Deliberately wasteful: a dict and a padded string per row, all
              # retained until the very end.
              rows.append({
                  "id": oid, "sku": sku,
                  "qty": int(qty), "price": float(price),
                  "pad": "x" * 4096,
              })

      lines = ["order_id,sku,qty,unit_price,total"]
      for r in rows:
          lines.append(
              f"{r['id']},{r['sku']},{r['qty']},{r['price']:.2f},{r['qty']*r['price']:.2f}"
          )

      with open("/srv/reports/daily.csv", "w") as out:
          out.write("\n".join(lines) + "\n")

      print(f"report-builder: wrote {len(rows)} rows", flush=True)
      SH
      chmod 0755 /usr/local/bin/report-builder

      cat > /etc/systemd/system/report-builder.service <<'UNIT'
      [Unit]
      Description=Nightly report builder

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/report-builder
      MemoryMax=48M
      UNIT

      systemctl daemon-reload
      rm -f /srv/reports/daily.csv

      # Run it once so the evidence is on the box, exactly as the student would
      # find it the morning after.
      systemctl start report-builder.service >/dev/null 2>&1 || true
      sleep 1

      # Ground truth, recorded before anything is changed.
      limit=$(systemctl show -p MemoryMax --value report-builder.service 2>/dev/null || echo "")
      printf '%s\n' "${limit:-50331648}" > /var/lib/devopslings/oom.limit
      echo oom > /var/lib/devopslings/oom.killer

      # What the finished report must contain, so shrinking the input fails.
      python3 - <<'PY'
      lines = ["order_id,sku,qty,unit_price,total"]
      with open('/srv/reports/orders.tsv') as f:
          for line in f:
              oid, sku, qty, price = line.rstrip("\n").split("\t")
              qty, price = int(qty), float(price)
              lines.append(f"{oid},{sku},{qty},{price:.2f},{qty*price:.2f}")
      open('/var/lib/devopslings/oom.expected', 'w').write("\n".join(lines) + "\n")
      PY
      sha256sum /var/lib/devopslings/oom.expected | awk '{print $1}' \
        > /var/lib/devopslings/oom.sha256

      cat > /root/questions.txt <<'Q'
      report-builder ran and produced nothing. Its own log says "starting" and
      stops there.

        /root/answers/killer   what ended it. One of:
                                 oom        the kernel's out-of-memory killer
                                 segfault   an invalid memory access
                                 exitcode   the program chose to exit non-zero
                                 signal     something sent it a terminating signal

        /root/answers/limit    the memory limit that was in effect when it died,
                               in bytes. Read it before you change anything.

      Then make report-builder complete and produce /srv/reports/daily.csv.
      The report must contain every one of the 20,000 orders.
      report-builder.service must still have a memory limit — not infinity.
      Q

      echo "scenario ready — report-builder.service produced no report"
      systemctl --no-pager --lines=3 status report-builder.service 2>&1 | tail -4 || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want_killer=$(cat /var/lib/devopslings/oom.killer)
      want_limit=$(cat /var/lib/devopslings/oom.limit)

      if [ ! -s /root/answers/killer ]; then
        echo "not yet: /root/answers/killer is missing or empty"
        echo "         one of: oom, segfault, exitcode, signal"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/killer | tr 'A-Z' 'a-z')
      if [ "$got" != "$want_killer" ]; then
        case "$got" in
          segfault)
            echo "not yet: a segfault leaves 'Segmentation fault' and usually a core dump"
            echo "         pattern in the journal. There is none here."
            ;;
          exitcode)
            echo "not yet: a program that chooses to exit gets to say why first. This one"
            echo "         printed 'starting' and never printed anything again — it did not"
            echo "         run any of its own error handling, because it never got to."
            ;;
          signal)
            echo "not yet: closer — it was killed by a signal. The question is who sent it"
            echo "         and why. Look at what systemd recorded about the unit, and at"
            echo "         the kernel's own log."
            ;;
          *)
            echo "not yet: '$got' is not one of oom, segfault, exitcode, signal"
            ;;
        esac
        exit 1
      fi

      if [ ! -s /root/answers/limit ]; then
        echo "not yet: /root/answers/limit is missing or empty (bytes)"
        exit 1
      fi
      gotlim=$(tr -dc '0-9' < /root/answers/limit)
      if [ "${gotlim:-0}" != "$want_limit" ]; then
        echo "not yet: /root/answers/limit says '${gotlim:-empty}', expected $want_limit"
        echo "         that is the limit that was in effect when it was killed —"
        echo "         'systemctl show -p MemoryMax report-builder.service', or"
        echo "         memory.max in the unit's cgroup. If you have already raised it,"
        echo "         reset the lesson and read it first."
        exit 1
      fi

      # A memory limit must still exist. "Remove the limit" is not a fix, it
      # just moves the failure to the whole box and makes it someone else's.
      lim=$(systemctl show -p MemoryMax --value report-builder.service 2>/dev/null || echo infinity)
      if [ "$lim" = "infinity" ] || [ -z "$lim" ]; then
        echo "not yet: report-builder.service has no memory limit any more"
        echo "         unbounded means the next oversized run takes the whole box down"
        echo "         instead of one unit. Keep a limit; make the work fit it, or raise"
        echo "         it to a number you chose on purpose."
        exit 1
      fi

      # It has to actually complete, from scratch, under whatever limit is now set.
      rm -f /srv/reports/daily.csv
      systemctl reset-failed report-builder.service >/dev/null 2>&1 || true
      if ! systemctl start report-builder.service >/dev/null 2>&1; then
        echo "not yet: report-builder.service still fails"
        systemctl --no-pager --lines=5 status report-builder.service 2>&1 | tail -6
        exit 1
      fi

      if [ ! -s /srv/reports/daily.csv ]; then
        echo "not yet: the unit succeeded and /srv/reports/daily.csv is missing or empty"
        exit 1
      fi

      want_sha=$(cat /var/lib/devopslings/oom.sha256)
      got_sha=$(sha256sum /srv/reports/daily.csv | awk '{print $1}')
      if [ "$got_sha" != "$want_sha" ]; then
        rows=$(( $(wc -l < /srv/reports/daily.csv) - 1 ))
        echo "not yet: daily.csv has $rows rows and does not match the expected report"
        echo "         (20,000 orders were expected). Processing fewer records fits the"
        echo "         limit and is not the same as building the report."
        exit 1
      fi

      echo "PASS — killed by the $want_killer at a ${want_limit}-byte limit; the report now"
      echo "       builds all 20,000 rows within MemoryMax=$lim."
---
