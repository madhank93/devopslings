---
kind: lesson
title: "exit 1, and not one word about why"
description: |
  The nightly ledger export fails. It prints nothing, logs nothing, and exits 1.
  The proposed fix is to chmod 777 everything it might touch. The kernel saw
  every file it asked for and every answer it got; ask strace which request
  was refused, fix exactly that, and leave nothing world-writable.
name: strace-the-silent-exit
slug: strace-the-silent-exit
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      systemctl stop ledger-export.service 2>/dev/null || true
      systemctl reset-failed ledger-export.service 2>/dev/null || true
      rm -rf /etc/ledger-export /var/lib/ledger-export /var/spool/ledger-export \
             /usr/local/bin/ledger-export /etc/systemd/system/ledger-export.service \
             /root/answers/silent-exit.txt /var/lib/devopslings/silent-exit.sha256
      id ledger >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ledger
      install -d /root/answers /var/lib/devopslings

      # Every failure path exits 1 without a message, as the real tool does:
      # the syscall trace is the only evidence of which one fired.
      cat > /usr/local/bin/ledger-export <<'PY'
      #!/usr/bin/python3
      import csv, datetime, os, sqlite3, sys

      def settings(path):
          out = {}
          with open(path) as f:
              for line in f:
                  if "=" in line and not line.startswith("#"):
                      k, v = line.split("=", 1)
                      out[k.strip()] = v.strip()
          return out

      try:
          conf = settings("/etc/ledger-export/export.conf")
          try:
              conf.update(settings("/etc/ledger-export/export.local.conf"))
          except FileNotFoundError:
              pass
          db = sqlite3.connect(f"file:{conf['db']}?mode=ro", uri=True)
          rows = db.execute("SELECT id, account, cents FROM entries ORDER BY id").fetchall()
          day = datetime.date.today().isoformat()
          tmp = os.path.join(conf["outdir"], f".ledger-{day}.{os.getpid()}.tmp")
          with open(tmp, "w", newline="") as f:
              w = csv.writer(f)
              w.writerow(["id", "account", "cents"])
              w.writerows(rows)
          os.rename(tmp, os.path.join(conf["outdir"], f"ledger-{day}.csv"))
      except Exception:
          sys.exit(1)
      PY
      chmod 0755 /usr/local/bin/ledger-export
      sha256sum /usr/local/bin/ledger-export | cut -d' ' -f1 > /var/lib/devopslings/silent-exit.sha256

      install -d -m 0755 /etc/ledger-export
      cat > /etc/ledger-export/export.conf <<'CONF'
      # ledger-export settings; export.local.conf, if present, overrides these
      db = /var/lib/ledger-export/ledger.db
      outdir = /var/spool/ledger-export/out
      CONF
      chmod 0644 /etc/ledger-export/export.conf

      install -d -m 0755 /var/lib/ledger-export
      python3 - <<'PY'
      import sqlite3
      db = sqlite3.connect("/var/lib/ledger-export/ledger.db")
      db.execute("CREATE TABLE entries (id INTEGER PRIMARY KEY, account TEXT, cents INTEGER)")
      db.executemany("INSERT INTO entries VALUES (?, ?, ?)",
                     [(i, f"ACC-{i % 17:03d}", (i * 7919) % 100000) for i in range(1, 501)])
      db.commit()
      PY
      chmod 0644 /var/lib/ledger-export/ledger.db

      # The spool was created by the packaging script as root; nobody gave it
      # to the service user.
      install -d -m 0755 /var/spool/ledger-export /var/spool/ledger-export/out

      cat > /etc/systemd/system/ledger-export.service <<'UNIT'
      [Unit]
      Description=Nightly ledger export

      [Service]
      Type=oneshot
      User=ledger
      ExecStart=/usr/local/bin/ledger-export
      UNIT
      systemctl daemon-reload
      systemctl start ledger-export.service >/dev/null 2>&1 || true

      echo "scenario ready — ledger-export.service failed with status 1 and logged nothing."
      echo "Write your findings to /root/answers/silent-exit.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=/root/answers/silent-exit.txt
      field() { { grep -iE "^$1=" "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "'; }

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing. It needs syscall=, errno= and path= for the call the"
        echo "         kernel refused, read from strace -f of the tool running as its own user."
        exit 1
      fi
      sc=$(field syscall); en=$(field errno | tr a-z A-Z); p=$(field path)
      if [ -z "$sc" ] || [ -z "$en" ] || [ -z "$p" ]; then
        echo "not yet: $ans needs all three of syscall=, errno= and path=."
        exit 1
      fi
      case "$p" in
        *export.local.conf*)
          echo "not yet: path=$p. That ENOENT is real, but the tool expects it: the file is an optional"
          echo "         override, and the trace carries on past it. The failure is the last refused"
          echo "         call before exit_group(1)."
          exit 1 ;;
        /usr/lib/python3*|*.so*|*.pyc*|*__pycache__*|*site-packages*)
          echo "not yet: path=$p is the interpreter searching its import path; every Python program"
          echo "         makes those failed calls on the way to a module it then finds. Read from the end"
          echo "         of the trace, backwards from exit_group(1)."
          exit 1 ;;
        /var/spool/ledger-export/out*) ;;
        *)
          echo "not yet: path=$p is not the call that ends the run. Trace the tool as the user the unit"
          echo "         runs it as (strace -f -u ledger ...); a root trace succeeds where ledger is refused."
          exit 1 ;;
      esac
      case "$sc" in
        openat|open|creat) ;;
        *) echo "not yet: syscall=$sc. The refused call is the one that tried to create a file in $p."; exit 1 ;;
      esac
      if [ "$en" != EACCES ]; then
        echo "not yet: errno=$en. strace prints the errno name after the -1 on the failing line."
        exit 1
      fi

      if [ "$(sha256sum /usr/local/bin/ledger-export | cut -d' ' -f1)" != "$(cat /var/lib/devopslings/silent-exit.sha256)" ]; then
        echo "not yet: /usr/local/bin/ledger-export has been changed. The tool is right; the box it runs"
        echo "         on is wrong. Reset the lesson to get the original back."
        exit 1
      fi
      user=$(systemctl show -p User --value ledger-export.service)
      if [ "$user" != ledger ]; then
        echo "not yet: ledger-export.service runs as '${user:-root}'. Root is not refused anything, which"
        echo "         hides the cause rather than fixing it; the export runs as ledger."
        exit 1
      fi
      ww=$(find /etc/ledger-export /var/lib/ledger-export /var/spool/ledger-export /usr/local/bin/ledger-export \
             -perm -0002 2>/dev/null || true)
      if [ -n "$ww" ]; then
        echo "not yet: world-writable now: $(echo $ww). Any local user can plant or replace the ledger"
        echo "         export there. Give the ledger user the access it needs and nobody else."
        exit 1
      fi

      out=/var/spool/ledger-export/out/ledger-$(date +%F).csv
      rm -f "$out"
      systemctl reset-failed ledger-export.service 2>/dev/null || true
      if ! systemctl start ledger-export.service >/dev/null 2>&1; then
        echo "not yet: the export still exits $(systemctl show -p ExecMainStatus --value ledger-export.service)."
        echo "         Trace it again as ledger and look at the last refused call."
        exit 1
      fi
      if [ ! -f "$out" ]; then
        echo "not yet: the export succeeded but wrote no $out. The nightly upload collects from"
        echo "         /var/spool/ledger-export/out; outdir in export.conf has to stay there."
        exit 1
      fi
      rows=$(( $(wc -l < "$out") - 1 ))
      if [ "$rows" != 500 ]; then
        echo "not yet: the export ran but $out has $rows rows, not 500."
        exit 1
      fi
      echo "PASS — openat in $p was refused with EACCES; the export now writes $rows rows as ledger,"
      echo "       and nothing it touches is world-writable."
---
