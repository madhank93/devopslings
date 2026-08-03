---
kind: lesson
title: "the export that has been running for nine hours at 0% CPU"
description: |
  export-orders is active, has burned no CPU since it started, and has produced
  nothing. There is no error anywhere. The kernel will tell you exactly what it
  is waiting for, if you ask it — and you have to ask before you fix it, because
  fixing it destroys the evidence.
name: blocked-on-a-pipe
slug: blocked-on-a-pipe
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /var/spool/export /srv/exports /root/answers /var/lib/devopslings

      # Deterministic on purpose: the check compares the bytes that come out
      # the far end of the pipeline against a fingerprint taken here, so the
      # export has to produce the same file every time.
      cat > /usr/local/bin/export-orders <<'SH'
      #!/bin/bash
      set -euo pipefail
      awk 'BEGIN {
        printf "order_id,sku,qty,unit_price\n"
        for (i = 1; i <= 20000; i++)
          printf "ORD-%06d,SKU-%04d,%d,%.2f\n", i, (i*7)%1000, (i%9)+1, ((i*13)%50000)/100
      }'
      SH
      chmod 0755 /usr/local/bin/export-orders

      /usr/local/bin/export-orders > /var/lib/devopslings/orders.expected
      sha256sum /var/lib/devopslings/orders.expected | awk '{print $1}' \
        > /var/lib/devopslings/blocked-on-a-pipe.sha256

      rm -f /var/spool/export/orders.fifo /srv/exports/orders.csv
      mkfifo -m 0644 /var/spool/export/orders.fifo

      # The producer. Correct, and it will never finish.
      # Deliberately no After= on the shipper. Ordering the producer after the
      # consumer would deadlock the moment the consumer is repaired: a oneshot
      # reader blocks on open until a writer arrives, and the writer would be
      # waiting for the reader to *finish*. The two ends of a FIFO have to be
      # allowed to run concurrently, which is the point of a FIFO.
      cat > /etc/systemd/system/export-orders.service <<'UNIT'
      [Unit]
      Description=Nightly order export

      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c '/usr/local/bin/export-orders > /var/spool/export/orders.fifo'
      UNIT

      # The consumer. One character wrong in the path, which is the whole
      # incident: it fails in a hundredth of a second, hours before anyone looks,
      # and its failure is not what anyone is called about.
      cat > /etc/systemd/system/orders-shipper.service <<'UNIT'
      [Unit]
      Description=Ship the order export

      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'cat /var/spool/export/order.fifo > /srv/exports/orders.csv'
      UNIT

      systemctl daemon-reload

      # The shipper ran at 03:00 and failed instantly.
      systemctl start orders-shipper.service >/dev/null 2>&1 || true

      # The export started right after and is still going.
      systemctl start --no-block export-orders.service >/dev/null 2>&1 || true

      # Wait for it to actually reach the blocking open before fingerprinting
      # what it is blocked in. Reading too early catches it mid-exec.
      wchan=""
      for _ in $(seq 1 60); do
        pid=$(systemctl show -p MainPID --value export-orders.service 2>/dev/null || echo 0)
        if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/wchan" ]; then
          w=$(cat "/proc/$pid/wchan" 2>/dev/null || true)
          if [ -n "$w" ] && [ "$w" != "0" ]; then wchan="$w"; break; fi
        fi
        sleep 0.25
      done

      if [ -z "$wchan" ]; then
        echo "scenario setup failed: the export did not reach a blocking state" >&2
        exit 1
      fi
      printf '%s\n' "$wchan" > /var/lib/devopslings/blocked-on-a-pipe.wchan

      cat > /root/questions.txt <<'Q'
      Write the kernel function the export is blocked in, and nothing else, to:

        /root/answers/wchan

      Read it off the running process before you repair anything. Once the
      pipeline completes, the process is gone and so is the evidence.
      (If you lose it, reset the lesson.)

      Then make the export actually complete, producing /srv/exports/orders.csv.
      Q

      echo "scenario ready — export-orders.service has been active since 03:00 and has written nothing"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      fifo=/var/spool/export/orders.fifo
      out=/srv/exports/orders.csv
      ans=/root/answers/wchan

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        echo "         the export is blocked right now — /proc/<pid>/wchan names the kernel"
        echo "         function it is sleeping in. Read it before you fix anything."
        exit 1
      fi

      want=$(cat /var/lib/devopslings/blocked-on-a-pipe.wchan)
      got=$(tr -d '[:space:]' < "$ans")
      if [ "$got" != "$want" ]; then
        echo "not yet: $ans says '$got', which is not what the export was waiting in"
        echo "         a blocked process's wchan is one symbol, e.g. the contents of"
        echo "         /proc/<pid>/wchan verbatim. If the process is already gone,"
        echo "         reset the lesson and read it before repairing the pipeline."
        exit 1
      fi

      if [ ! -p "$fifo" ]; then
        echo "not yet: $fifo is not a named pipe any more"
        echo "         replacing the pipe with a regular file makes the writer finish and"
        echo "         changes what the pipeline is. Reset the lesson."
        exit 1
      fi

      # Prove the pipeline works now, rather than that a file happens to exist.
      # Everything is torn down and run again from scratch on every check.
      systemctl stop export-orders.service >/dev/null 2>&1 || true
      systemctl stop orders-shipper.service >/dev/null 2>&1 || true
      systemctl reset-failed export-orders.service orders-shipper.service >/dev/null 2>&1 || true
      rm -f "$out"

      # Whichever end opens first blocks until the other arrives, so the order
      # these are started in does not matter.
      systemctl start --no-block orders-shipper.service >/dev/null 2>&1 || true
      systemctl start --no-block export-orders.service >/dev/null 2>&1 || true

      want_sha=$(cat /var/lib/devopslings/blocked-on-a-pipe.sha256)
      ok=""
      for _ in $(seq 1 80); do
        if [ -f "$out" ]; then
          got_sha=$(sha256sum "$out" 2>/dev/null | awk '{print $1}')
          if [ "$got_sha" = "$want_sha" ]; then ok=yes; break; fi
        fi
        sleep 0.5
      done

      if [ -z "$ok" ]; then
        echo "not yet: the pipeline did not deliver the export"
        echo "         $out: $( [ -f "$out" ] && wc -c < "$out" || echo missing ) bytes,"
        echo "         expected $(wc -c < /var/lib/devopslings/orders.expected) bytes"
        systemctl --no-pager --lines=3 status orders-shipper.service 2>&1 | tail -4
        exit 1
      fi

      shipper=$(systemctl show -p Result --value orders-shipper.service 2>/dev/null || echo unknown)
      if [ "$shipper" != "success" ]; then
        echo "not yet: $out has the right contents but orders-shipper.service reports '$shipper'"
        echo "         the data has to arrive through the pipe the two units share, not"
        echo "         around it."
        exit 1
      fi

      rows=$(( $(wc -l < "$out") - 1 ))
      echo "PASS — blocked in $want; the pipeline now delivers $rows rows through $fifo."
---
