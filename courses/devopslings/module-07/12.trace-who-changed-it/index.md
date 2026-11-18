---
kind: lesson
title: "the refund limit changed at 02:14 and nobody admits to it"
description: |
  Someone keeps raising the payment service's refund limit from 500 to 50000.
  The file's mtime says when, and alice's shell history says she edited it —
  but neither says who wrote it last. Only a trail recorded by the kernel at the
  moment of the write can: who, which process, which syscall. The work is
  writing the watch that would have caught it, then reading what it catches.
name: trace-who-changed-it
slug: trace-who-changed-it
createdAt: "2026-11-17"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # ---- clean slate ---------------------------------------------------
      systemctl stop cache-warmer.service 2>/dev/null || true
      systemctl reset-failed cache-warmer.service 2>/dev/null || true
      rm -rf /etc/pay /usr/local/lib/cache-warmer /root/watch.bt \
             /root/answers/who.md /etc/systemd/system/cache-warmer.service
      getent group payops >/dev/null || groupadd payops
      for u in alice carol dave; do
        id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
        usermod -aG payops "$u"
      done
      id svc-cache >/dev/null 2>&1 || useradd --system --no-create-home \
          --shell /usr/sbin/nologin svc-cache
      usermod -aG payops svc-cache
      install -d /root/answers

      # bpftrace's tracepoints live in tracefs; a host has it mounted, a
      # container has to be told.
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the payment service's limits ----------------------------------
      install -d -o root -g payops -m 2775 /etc/pay
      printf 'currency = EUR\nmax_refund = 500\nmax_daily = 20000\n' > /etc/pay/limits.conf
      chown root:payops /etc/pay/limits.conf
      chmod 0664 /etc/pay/limits.conf
      echo 'refund limits approved by finance, 2026-10-01' > /etc/pay/NOTES
      touch -d '02:14' /etc/pay/limits.conf

      # ---- the red herring: alice did edit it, weeks ago -----------------
      cat > /home/alice/.bash_history <<'H'
      cd /etc/pay
      cat limits.conf
      vi /etc/pay/limits.conf
      systemctl status payments
      exit
      H
      chown alice:alice /home/alice/.bash_history
      touch -d '02:10' /home/alice/.bash_history

      # ---- the culprit: a service account that "warms a cache" -----------
      # It writes in place from bash, so the inode and owner never change and
      # only the content and mtime betray it.
      install -d /usr/local/lib/cache-warmer
      cat > /usr/local/lib/cache-warmer/warm <<'W'
      #!/bin/bash
      while sleep 10; do
        conf=$(sed 's/^max_refund = .*/max_refund = 50000/' /etc/pay/limits.conf)
        printf '%s\n' "$conf" > /etc/pay/limits.conf
      done
      W
      chmod 0755 /usr/local/lib/cache-warmer/warm
      cat > /etc/systemd/system/cache-warmer.service <<'U'
      [Unit]
      Description=Warm the payment lookup cache

      [Service]
      User=svc-cache
      ExecStart=/usr/local/lib/cache-warmer/warm
      Restart=always

      [Install]
      WantedBy=multi-user.target
      U
      systemctl daemon-reload
      systemctl enable --now cache-warmer.service

      cat > /root/questions.txt <<'Q'
      /etc/pay/limits.conf caps refunds at 500. Last night at 02:14 it changed to
      50000. Finance put it back; it changed again. Nobody admits to it.

        $ stat /etc/pay/limits.conf        when, not who
        $ cat /home/alice/.bash_history    alice did open it in vi, once

      mtime and shell history are guesses. Write the watch that records who
      changes this file, as it happens:

        /root/watch.bt   a bpftrace program; for every change to
                         /etc/pay/limits.conf it prints one line naming the
                         user (name or uid), the process (comm) and the syscall

      It must not report reads, and must not report changes to any other file.
      A change can be an in-place write or a rename over the file (what sed -i
      and most editors do) — both count.

      The grader runs your watch while it reads the file, edits it with sed -i,
      appends to it, and writes a file next to it.

      Run it yourself (bpftrace /root/watch.bt) and wait for the next change.
      Then write /root/answers/who.md:

        user: <who changed it>
        process: <the process that wrote it>
        syscall: <the syscall your watch caught it in>
      Q

      echo "scenario ready — someone keeps raising max_refund in /etc/pay/limits.conf"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      set -e

      f=/etc/pay/limits.conf
      w=/root/watch.bt
      ans=/root/answers/who.md

      if [ ! -s "$w" ]; then
        echo "not yet: /root/watch.bt is missing or empty. Write a bpftrace program"
        echo "         that prints who changes $f."
        exit 1
      fi
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # The probes run as fresh copies of real tools, so each one's comm is
      # unknowable in advance and can only show up if the watch truly saw it.
      tag=$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')
      probe=/usr/local/lib/watch-probe
      rd=rd-$tag ed=ed-$tag ap=ap-$tag nb=nb-$tag
      reset_probe() {
        rm -rf "$probe" /etc/pay/notes.txt /etc/pay/sed*
        if [ -f "$f" ]; then chown root:payops "$f"; chmod 0664 "$f"; fi
      }
      reset_probe
      trap reset_probe EXIT
      install -d -m 0755 "$probe"
      cp /usr/bin/cat "$probe/$rd"
      cp /usr/bin/sed "$probe/$ed"
      cp /usr/bin/dash "$probe/$ap"
      cp /usr/bin/dash "$probe/$nb"

      out=$(mktemp)
      bpftrace "$w" > "$out" 2>&1 &
      bt=$!
      for _ in $(seq 120); do
        grep -q '^Attaching' "$out" && break
        kill -0 "$bt" 2>/dev/null || break
        sleep 0.5
      done
      if ! kill -0 "$bt" 2>/dev/null || ! grep -q '^Attaching' "$out"; then
        kill "$bt" 2>/dev/null || true
        echo "not yet: bpftrace did not attach your watch. Its output:"
        tail -n 8 "$out" | sed 's/^/         /'
        rm -f "$out"
        exit 1
      fi
      sleep 1

      runuser -u alice -- "$probe/$rd" "$f" > /dev/null
      runuser -u dave -- "$probe/$ap" -c "printf '' >> $f"
      runuser -u carol -- "$probe/$ed" -i 's/^currency = .*/currency = EUR/' "$f"
      "$probe/$nb" -c 'echo probe > /etc/pay/notes.txt'
      sleep 2
      kill -INT "$bt" 2>/dev/null || true
      wait "$bt" 2>/dev/null || true
      log=$(cat "$out")
      rm -f "$out"
      reset_probe
      trap - EXIT

      names() { printf '%s\n' "$log" | grep -F "$1" || true; }
      # Some kernels (Ubuntu's 7.0) run BPF on syscalls:sys_enter_* only for
      # syscalls made on CPU 0, so such a watch misses most changes.
      cpu0_note() {
        grep -q 'syscalls:sys_enter_' "$w" || return 0
        echo "         If you are sure the filter is right: on some kernels the"
        echo "         per-syscall sys_enter_* tracepoints reach bpftrace only for"
        echo "         syscalls made on CPU 0. tracepoint:raw_syscalls:sys_enter"
        echo "         sees every CPU — the unit shows how."
      }
      identifies() {
        printf '%s\n' "$1" | grep -Eq "\\b($2|$(id -u "$2"))\\b"
      }

      if [ -n "$(names "$rd")" ]; then
        echo "not yet: alice read $f with '$rd' and your watch reported it:"
        names "$rd" | head -n 2 | sed 's/^/         /'
        echo "         A read changes nothing. Report opens for writing only — the"
        echo "         low bits of openat's flags say which (O_RDONLY is 0)."
        exit 1
      fi
      if [ -n "$(names "$nb")" ]; then
        echo "not yet: root wrote /etc/pay/notes.txt with '$nb' and your watch"
        echo "         reported it. Filter on the one path, not every write."
        exit 1
      fi
      line=$(names "$ap")
      if [ -z "$line" ]; then
        echo "not yet: dave appended to $f with '$ap' and your watch printed"
        echo "         nothing for it. An append is an openat with a write flag."
        cpu0_note
        exit 1
      fi
      if ! identifies "$line" dave; then
        echo "not yet: your watch caught dave's append but the line does not"
        echo "         name the user (dave, or uid $(id -u dave)):"
        printf '%s\n' "$line" | head -n 1 | sed 's/^/         /'
        exit 1
      fi
      line=$(names "$ed")
      if [ -z "$line" ]; then
        echo "not yet: carol ran sed -i on $f (as '$ed') and your watch printed"
        echo "         nothing. sed -i writes a temporary file and renames it over"
        echo "         the original — the path arrives as rename's new name, not in"
        echo "         an openat."
        cpu0_note
        exit 1
      fi
      if ! identifies "$line" carol; then
        echo "not yet: your watch caught carol's sed -i but the line does not"
        echo "         name the user (carol, or uid $(id -u carol)):"
        printf '%s\n' "$line" | head -n 1 | sed 's/^/         /'
        exit 1
      fi

      # ---- the answer ----------------------------------------------------
      if [ ! -s "$ans" ]; then
        echo "not yet: the watch works. Now run it, wait for the next change and"
        echo "         write /root/answers/who.md: user, process, syscall."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -n 1; }
      a_user=$(field user) a_proc=$(field process) a_sys=$(field syscall)

      if printf '%s' "$a_user" | grep -Eq '\balice\b'; then
        echo "not yet: user says alice. Her history shows she opened the file in"
        echo "         vi once — not that she wrote it last, or at all. Run the"
        echo "         watch and let the next change name its writer."
        exit 1
      fi
      if ! printf '%s' "$a_user" | grep -Eq "\\b(svc-cache|$(id -u svc-cache))\\b"; then
        echo "not yet: user says '${a_user:-nothing}'. Run your watch for ten"
        echo "         seconds and read the user off the line it prints."
        exit 1
      fi
      if ! printf '%s' "$a_proc" | grep -Eq '\b(warm|cache-warmer)\b'; then
        echo "not yet: process says '${a_proc:-nothing}'. Name the process your"
        echo "         watch printed for that change."
        exit 1
      fi
      if ! printf '%s' "$a_sys" | grep -Eq '\bopen(at)?\b'; then
        echo "not yet: syscall says '${a_sys:-nothing}'. The writer opens the file"
        echo "         for writing each time — which syscall carries the path and"
        echo "         the write flag?"
        exit 1
      fi

      echo "PASS — the watch names the user, process and syscall for an in-place"
      echo "       write and a rename, and stays quiet for reads and other files."
      echo "       svc-cache's cache-warmer has been rewriting the refund limit."
