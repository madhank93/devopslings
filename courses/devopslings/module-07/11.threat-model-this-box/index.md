---
kind: lesson
title: "one host, written up properly"
description: |
  A threat model that says "hackers could steal the data" has named nobody and
  nothing. This one is about one real box: its assets, its ways in, the
  boundaries between who runs what, and the one control it is missing. The
  grader checks every claim against the box, wants each attacker described by
  what they can already do, and refuses any control that claims to be free.
name: threat-model-this-box
slug: threat-model-this-box
createdAt: "2026-10-14"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop invoice-web.service 2>/dev/null || true
      systemctl reset-failed invoice-web.service 2>/dev/null || true
      rm -rf /etc/systemd/system/invoice-web.service /etc/systemd/system/invoice-web.service.d \
             /opt/invoice /etc/invoice /var/lib/invoice /var/backups/invoice \
             /root/answers/threat-model.md /root/host-notes.md
      rm -f /etc/cron.d/invoice-backup /etc/sudoers.d/deployer \
            /usr/local/sbin/invoice-backup
      id invoice >/dev/null 2>&1 || useradd --system --home-dir /var/lib/invoice --no-create-home \
        --shell /usr/sbin/nologin invoice
      id deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
      install -d /root/answers

      # ---- the invoice app ---------------------------------------------
      install -d -o invoice -g invoice -m 0755 /opt/invoice /opt/invoice/bin
      install -d -o invoice -g invoice -m 0750 /var/lib/invoice
      install -d -o root -g root -m 0700 /var/backups/invoice
      install -d -m 0755 /etc/invoice

      # The prefix is invented so the value cannot pass for a real provider key.
      printf 'PAYMENT_API_KEY=payk_demo_%s\n' "$(openssl rand -hex 16)" > /etc/invoice/payment.env
      chown root:invoice /etc/invoice/payment.env
      chmod 0640 /etc/invoice/payment.env

      python3 - <<'PY'
      import sqlite3
      db = sqlite3.connect("/var/lib/invoice/invoices.db")
      db.execute("create table invoices (id integer primary key, customer text, address text, amount_cents integer, status text)")
      db.executemany("insert into invoices (customer, address, amount_cents, status) values (?, ?, ?, ?)", [
          ("Harbour Lane Bakery", "14 Harbour Lane", 48200, "open"),
          ("Okafor Joinery", "3 Mill Yard", 129000, "paid"),
          ("Vale Street Dental", "88 Vale Street", 23650, "open"),
      ])
      db.commit()
      PY
      chown invoice:invoice /var/lib/invoice/invoices.db
      chmod 0640 /var/lib/invoice/invoices.db

      cat > /opt/invoice/app.py <<'PY'
      import http.server
      import sqlite3

      DB = "/var/lib/invoice/invoices.db"
      KEY = "/etc/invoice/payment.env"


      class Invoices(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              # The provider key is read per request so a rotated key needs no restart.
              with open(KEY) as f:
                  key_loaded = f.read().startswith("PAYMENT_API_KEY=")
              rows = sqlite3.connect(DB).execute(
                  "select id, customer, amount_cents, status from invoices").fetchall()
              body = "".join(f"{r[0]} {r[1]} {r[2] / 100:.2f} {r[3]}\n" for r in rows)
              body += f"payments: {'ready' if key_loaded else 'no key'}\n"
              data = body.encode()
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(data)))
              self.end_headers()
              self.wfile.write(data)

          def log_message(self, *args):
              pass


      class Server(http.server.ThreadingHTTPServer):
          allow_reuse_address = True


      Server(("0.0.0.0", 8180), Invoices).serve_forever()
      PY
      chown invoice:invoice /opt/invoice/app.py

      cat > /opt/invoice/bin/backup.sh <<'SH'
      #!/bin/sh
      # Nightly copy of the invoice database, kept 14 days.
      set -eu
      install -d -m 0700 /var/backups/invoice
      cp /var/lib/invoice/invoices.db "/var/backups/invoice/invoices-$(date +%F).db"
      find /var/backups/invoice -name 'invoices-*.db' -mtime +14 -delete
      SH
      chown invoice:invoice /opt/invoice/bin/backup.sh
      chmod 0755 /opt/invoice/bin/backup.sh

      printf '%s\n' \
        '# Nightly invoice backup. /var/backups is root-only, so this runs as root.' \
        '15 2 * * * root /opt/invoice/bin/backup.sh' \
        > /etc/cron.d/invoice-backup
      chmod 0644 /etc/cron.d/invoice-backup

      cat > /etc/systemd/system/invoice-web.service <<'UNIT'
      [Unit]
      Description=invoice web app
      After=network.target

      [Service]
      User=invoice
      Group=invoice
      ExecStart=/usr/bin/python3 /opt/invoice/app.py
      Restart=on-failure
      RestartSec=1

      [Install]
      WantedBy=multi-user.target
      UNIT

      # ---- deployer: CI logs in with a key and restarts the app ----------
      install -d -o deployer -g deployer -m 0700 /home/deployer/.ssh
      keydir=$(mktemp -d)
      ssh-keygen -q -t ed25519 -N '' -C 'ci@build-runner' -f "$keydir/ci"
      install -o deployer -g deployer -m 0600 "$keydir/ci.pub" /home/deployer/.ssh/authorized_keys
      rm -rf "$keydir"

      echo 'deployer ALL=(root) NOPASSWD: /usr/bin/systemctl restart invoice-web.service' \
        > /etc/sudoers.d/deployer
      chmod 0440 /etc/sudoers.d/deployer
      visudo -cf /etc/sudoers.d/deployer >/dev/null

      # ---- sshd --------------------------------------------------------
      systemctl mask ssh.socket >/dev/null 2>&1 || true
      ssh-keygen -A >/dev/null 2>&1
      printf '%s\n' \
        'Port 22' \
        'PermitRootLogin no' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PubkeyAuthentication yes' \
        'Subsystem sftp /usr/lib/openssh/sftp-server' \
        > /etc/ssh/sshd_config
      install -d -m 0755 /run/sshd
      sshd -t

      systemctl daemon-reload
      systemctl enable ssh.service invoice-web.service cron.service >/dev/null 2>&1
      systemctl reset-failed ssh.service invoice-web.service >/dev/null 2>&1 || true
      systemctl restart ssh.service invoice-web.service cron.service

      ok=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://127.0.0.1:8180/ 2>/dev/null | grep -q 'payments: ready' \
           && ss -ltnH 'sport = :22' | grep -q .; then ok=yes; break; fi
        sleep 0.25
      done
      if [ -z "$ok" ]; then
        echo "the scenario did not come up: invoice-web or sshd is not answering"
        exit 1
      fi

      cat > /root/host-notes.md <<'NOTES'
      # invoice-1

      Runs the invoicing web app for the accounts team's customers.

      - invoice-web.service, /opt/invoice/app.py, as the `invoice` user.
        Public traffic comes through the company load balancer, which
        terminates TLS and forwards plain HTTP to tcp/8180 on this host.
      - Data lives in /var/lib/invoice/. The payment provider key is in
        /etc/invoice/; the app reads it on every request.
      - CI deploys over SSH as `deployer` (key only, no passwords) and restarts
        the app with sudo. That is the only thing deployer can do as root.
      - A nightly cron job backs the database up to /var/backups/invoice/.
      NOTES

      cat > /root/answers/threat-model.md <<'TPL'
      # Threat model: invoice-1
      #
      # One item per line, key at the start of the line. Lines starting with #
      # are ignored. Add as many lines of each kind as you need.
      #
      # asset:     something worth protecting, named by its path on this box
      # entry:     a way in, written tcp/<port>, and who can reach it
      # boundary:  <principal> -> <principal> via <what crosses>
      #            principals: internet, deployer, invoice, root
      # threat:    can=<what the attacker is already able to do> gets=<what that gives them>
      # missing:   the path of the file where a control is missing, and what is missing
      # control:   <what you would change> | cost: <what it costs>

      asset:
      asset:

      entry:
      entry:

      boundary:
      boundary:

      threat:
      threat:

      missing:

      control:
      TPL

      cat > /root/questions.txt <<'Q'
      This box is invoice-1. /root/host-notes.md is what its owners wrote about
      it. Check every line of that against the box itself before you rely on it.

      Write a threat model of this host into /root/answers/threat-model.md. The
      template is already there:

        assets        what is worth taking, by path
        entry points  the ports that are listening, and who reaches them
        boundaries    where control passes from one principal to another
        threats       what an attacker can already do, and what it gets them
        missing       the one control this box does not have
        controls      what you would change, and what each change costs

      Every claim is checked against the box. An attacker is described by what
      they can do, not by what they are called. A control without a cost is not
      accepted.

      Nothing needs to be changed on the box. This is graded on the write-up.
      Q

      echo "scenario ready — invoice-1 is up; notes in /root/host-notes.md,"
      echo "template in /root/answers/threat-model.md"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=/root/answers/threat-model.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      # Non-empty values for one key, one per line, key stripped.
      field() {
        grep -iE "^[[:space:]]*$1:" "$ans" \
          | sed -E 's/^[[:space:]]*[A-Za-z_]+:[[:space:]]*//; s/[[:space:]]+$//' \
          | grep -v '^$' || true
      }
      count() { printf '%s' "$1" | grep -c . || true; }
      # First absolute path in a line; tcp/<port> is a port, not a path.
      first_path() {
        printf '%s\n' "$1" | sed -E 's#(tcp|udp)/[0-9]+##g' \
          | grep -oE '/[A-Za-z0-9._/-]*[A-Za-z0-9_-]' | sed -n 1p || true
      }
      lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
      staged_ports="8180 22"

      # ---- assets ------------------------------------------------------
      assets=$(field asset)
      n=$(count "$assets"); : "${n:=0}"
      if [ "$n" -lt 2 ]; then
        echo "not yet: list at least two assets, one per 'asset:' line, each named"
        echo "         by its path on this box."
        exit 1
      fi
      have_key=""; have_db=""
      while IFS= read -r a; do
        p=$(first_path "$a")
        if [ -z "$p" ]; then
          echo "not yet: this asset names no path:"
          echo "           asset: $a"
          echo "         Name each asset by where it lives on this box, so the claim"
          echo "         can be checked."
          exit 1
        fi
        if [ ! -e "$p" ]; then
          echo "not yet: the asset $p does not exist on this box."
          echo "         A threat model is of the host in front of you; every asset has"
          echo "         to be something you found on it."
          exit 1
        fi
        case "$p" in
          /etc/invoice|/etc/invoice/payment.env) have_key=yes ;;
          /var/lib/invoice|/var/lib/invoice/invoices.db) have_db=yes ;;
        esac
      done <<< "$assets"
      if [ -z "$have_key" ]; then
        echo "not yet: none of your assets is the payment provider key. invoice-web"
        echo "         reads a credential on every request; find the file. It is the"
        echo "         most valuable thing to steal from this box."
        exit 1
      fi
      if [ -z "$have_db" ]; then
        echo "not yet: none of your assets is the invoice data itself. Find where"
        echo "         invoice-web keeps what it serves."
        exit 1
      fi

      # ---- entry points ------------------------------------------------
      entries=$(field entry)
      seen=" "
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        ports=$(printf '%s\n' "$e" | grep -oiE 'tcp/[0-9]+' | cut -d/ -f2 || true)
        if [ -z "$ports" ]; then
          echo "not yet: this entry names no port; write each one as tcp/<port>:"
          echo "           entry: $e"
          exit 1
        fi
        for p in $ports; do
          case " $staged_ports " in
            *" $p "*) ;;
            *)
              if ! ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
                echo "not yet: nothing listens on tcp/$p on this box. Entry points come"
                echo "         from 'ss -ltnp', not from what a box like this usually runs."
                exit 1
              fi ;;
          esac
          seen="$seen$p "
        done
      done <<< "$entries"
      case "$seen" in
        *" 8180 "*) ;;
        *) echo "not yet: tcp/8180 is not among your entry points. It is the web app,"
           echo "         and it is the one the internet reaches."
           exit 1 ;;
      esac
      case "$seen" in
        *" 22 "*) ;;
        *) echo "not yet: tcp/22 is not among your entry points. sshd listens on every"
           echo "         interface. Key-only login makes it a narrow way in, not a"
           echo "         closed one."
           exit 1 ;;
      esac

      # ---- trust boundaries --------------------------------------------
      bounds=$(field boundary)
      pairs=" "
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        case "$b" in
          *"->"*) ;;
          *) echo "not yet: this boundary has no '->':"
             echo "           boundary: $b"
             echo "         Write it as <principal> -> <principal> via <what crosses>."
             exit 1 ;;
        esac
        from=$(lc "${b%%->*}" | awk '{print $1}')
        to=$(lc "${b#*->}" | awk '{print $1}')
        for side in "$from" "$to"; do
          case "$side" in
            internet|deployer|invoice|root) ;;
            *) echo "not yet: '$side' is not one of the principals: internet, deployer,"
               echo "         invoice, root. A trust boundary sits between two of them:"
               echo "           boundary: $b"
               exit 1 ;;
          esac
        done
        if [ "$from" = "$to" ]; then
          echo "not yet: this boundary has $from on both sides:"
          echo "           boundary: $b"
          echo "         A boundary is where control passes from one principal to a"
          echo "         different one."
          exit 1
        fi
        pairs="$pairs$from:$to $to:$from "
      done <<< "$bounds"
      case "$pairs" in
        *" internet:invoice "*) ;;
        *) echo "not yet: no boundary between internet and invoice. Requests from"
           echo "         anyone reach code running as the invoice user; that is the"
           echo "         first crossing on this box."
           exit 1 ;;
      esac
      case "$pairs" in
        *" invoice:root "*) ;;
        *) echo "not yet: no boundary between invoice and root. Something root does on"
           echo "         this box depends on a file the invoice user controls. Find it:"
           echo "         that crossing is where this box's gap is."
           exit 1 ;;
      esac

      # ---- the missing control -----------------------------------------
      m=$(field missing | sed -n 1p)
      ml=$(lc "$m")
      if [ -z "$m" ]; then
        echo "not yet: no 'missing:' line. Name the file where a control is missing."
        exit 1
      fi
      if printf '%s' "$ml" | grep -Eq '^(none|nothing|n/?a)([[:space:][:punct:]]|$)|\bnothing (is )?missing\b|\bno (controls? )?(is |are )?missing\b|\b(is|are) (fine|ok|okay|safe|secure|correct)\b|\bnot (a|the) (gap|problem|issue)\b'; then
        echo "not yet: your 'missing:' line says nothing is missing. One control is:"
        echo "         look for something root runs that root does not control."
        exit 1
      fi
      p=$(first_path "$m")
      if [ -z "$p" ]; then
        if printf '%s' "$ml" | grep -Eq '\b(firewall|iptables|nftables|nft|ufw)\b'; then
          echo "not yet: 'missing:' names no file. A firewall would not close the gap"
          echo "         here: both listening ports are meant to be reachable, and the"
          echo "         gap is in what happens after someone has a foothold."
        elif printf '%s' "$ml" | grep -Eq '\b(tls|https|ssl|encrypt[a-z]*)\b'; then
          echo "not yet: 'missing:' names no file. TLS ends at the load balancer in"
          echo "         front of tcp/8180 (see /root/host-notes.md); that is by design."
        else
          echo "not yet: 'missing:' names no file. Give the path where the control"
          echo "         is missing, so the claim can be checked against the box."
        fi
        exit 1
      fi
      if [ ! -e "$p" ]; then
        echo "not yet: '$p' does not exist on this box."
        exit 1
      fi
      case "$p" in
        /opt/invoice/bin|/opt/invoice/bin/backup.sh) ;;
        /opt/invoice|/opt/invoice/app.py)
          echo "not yet: $p is the app itself, and a service user owning"
          echo "         its own code is how most services ship. Which file under"
          echo "         /opt/invoice is run by someone other than invoice?"
          exit 1 ;;
        /etc/cron.d|/etc/cron.d/invoice-backup)
          echo "not yet: /etc/cron.d/invoice-backup is root:root 0644; only root can"
          echo "         change it. Look at what it runs, and who owns that."
          exit 1 ;;
        /etc/invoice|/etc/invoice/payment.env)
          echo "not yet: payment.env is root:invoice 0640: the service reads it and no"
          echo "         one else can. Whatever you would add there, the gap on this box"
          echo "         is in something root runs."
          exit 1 ;;
        /etc/ssh|/etc/ssh/sshd_config)
          echo "not yet: sshd already refuses passwords and root logins. Whatever you"
          echo "         would add there, the gap on this box is in something root runs."
          exit 1 ;;
        /etc/sudoers|/etc/sudoers.d|/etc/sudoers.d/deployer)
          echo "not yet: deployer may run exactly one command as root, a restart of"
          echo "         invoice-web. That grant is narrow; it is not the gap."
          exit 1 ;;
        /home/deployer*)
          echo "not yet: deployer logs in with one key and no password. Whatever you"
          echo "         would add there, the gap on this box is in something root runs."
          exit 1 ;;
        /var/lib/invoice*|/var/backups*)
          echo "not yet: $p is data, and its owner and mode are already"
          echo "         as tight as its readers allow. The gap is in something that runs."
          exit 1 ;;
        *)
          echo "not yet: $p exists, but it is not where the gap is."
          echo "         Look for something root executes that a less trusted user can"
          echo "         change."
          exit 1 ;;
      esac

      # ---- threats -----------------------------------------------------
      threats=$(field threat)
      n=$(count "$threats"); : "${n:=0}"
      if [ "$n" -lt 2 ]; then
        echo "not yet: write at least two threats, one per 'threat:' line, as"
        echo "         can=<what the attacker can already do> gets=<what that gives them>."
        exit 1
      fi
      vague='\b(hackers?|bad (actors?|guys?)|malicious (actors?|users?|people|parties)|attackers?|adversar(y|ies)|threat actors?|cyber ?criminals?|criminals?|intruders?|someone|anyone|nation[- ]states?)\b'
      verbs='\b(send|sends|run|runs|execute|executes|read|reads|write|writes|modify|modifies|edit|edits|replace|replaces|reach|reaches|connect|connects|log in|logs in|login|steal|steals|stole|hold|holds|has|have|possess|possesses|upload|uploads|guess|guesses|intercept|intercepts|sniff|sniffs|inject|injects|control|controls)\b'
      to_root=""
      while IFS= read -r t; do
        tl=$(lc "$t")
        can=$(printf '%s' "$tl" | sed -n 's/.*can=//p' | sed 's/[[:space:]]*gets=.*//')
        gets=$(printf '%s' "$tl" | sed -n 's/.*gets=//p' | sed 's/[[:space:]]*$//')
        if [ -z "$can" ]; then
          echo "not yet: this threat has no can=; say what the attacker is already"
          echo "         able to do:"
          echo "           threat: $t"
          exit 1
        fi
        if ! printf '%s' "$can" | grep -Eq "$verbs"; then
          who=$(printf '%s' "$can" | grep -oE "$vague" | sed -n 1p || true)
          if [ -n "$who" ]; then
            echo "not yet: this threat says who the attacker is ('$who'), not what they"
            echo "         can do:"
            echo "           threat: $t"
            echo "         Write the capability, for example 'can=send HTTP requests to"
            echo "         tcp/8180' or 'can=read files as invoice'."
          else
            echo "not yet: 'can=$can' is not a capability:"
            echo "           threat: $t"
            echo "         Start with what the attacker can do: send, read, write, run,"
            echo "         log in, hold."
          fi
          exit 1
        fi
        concrete=""
        if printf '%s' "$can" | grep -Eq '\btcp/(8180|22)\b|\bport (8180|22)\b|\b(invoice|deployer|root)\b'; then
          concrete=yes
        else
          cp=$(first_path "$can")
          if [ -n "$cp" ] && [ -e "$cp" ]; then concrete=yes; fi
        fi
        if [ -z "$concrete" ]; then
          echo "not yet: 'can=$can' does not say where:"
          echo "           threat: $t"
          echo "         Tie the capability to this box: a port (tcp/8180, tcp/22), a"
          echo "         user (invoice, deployer, root) or a file that exists here."
          exit 1
        fi
        if [ -z "$gets" ]; then
          echo "not yet: this threat has no gets=:"
          echo "           threat: $t"
          echo "         A capability matters for what it reaches: name the asset or the"
          echo "         privilege."
          exit 1
        fi
        if printf '%s' "$gets" | grep -Eq '\broot\b'; then to_root=yes; fi
      done <<< "$threats"
      if [ -z "$to_root" ]; then
        echo "not yet: none of your threats ends in gets=root. The gap you named in"
        echo "         'missing:' is a path from the invoice user to root. Write the"
        echo "         threat it leaves open."
        exit 1
      fi

      # ---- controls ----------------------------------------------------
      controls=$(field control)
      if [ -z "$controls" ]; then
        echo "not yet: no 'control:' lines. Write what you would change, with"
        echo "         '| cost: ...' on the same line."
        exit 1
      fi
      closes=""
      while IFS= read -r c; do
        what=$(printf '%s' "$c" | sed -E 's/[[:space:]]*\|?[[:space:]]*[Cc][Oo][Ss][Tt]:.*//')
        if ! printf '%s' "$c" | grep -iq 'cost:'; then
          echo "not yet: this control has no cost:"
          echo "           control: $c"
          echo "         Every control costs something: an outage risk, a slower deploy,"
          echo "         a step someone has to remember. Add '| cost: ...' to the line."
          exit 1
        fi
        cost=$(lc "$c" | sed 's/.*cost:[[:space:]]*//')
        if [ -z "$cost" ]; then
          echo "not yet: this control has an empty cost:"
          echo "           control: $c"
          exit 1
        fi
        if printf '%s' "$cost" | grep -Eq '^(none|nothing|nil|zero|free|negligible|minimal|trivial|n/?a|-+)([[:punct:]]|$)|\bcosts? nothing\b|\bno (real |extra |additional )?(cost|downside|impact|overhead)\b|\bfor free\b|\bzero cost\b|\bwithout (any )?(cost|downside)\b'; then
          echo "not yet: this control claims to cost nothing:"
          echo "           control: $c"
          echo "         Something always pays: who has to do more, what gets slower,"
          echo "         or what breaks if it is applied wrong."
          exit 1
        fi
        if [ "$(printf '%s' "$cost" | tr -d '[:space:]' | wc -c)" -lt 15 ]; then
          echo "not yet: this control's cost is too short to say anything:"
          echo "           control: $c"
          echo "         Say who pays it and how."
          exit 1
        fi
        if printf '%s' "$what" | grep -Eq 'backup|/opt/invoice/bin|cron'; then closes=yes; fi
      done <<< "$controls"
      if [ -z "$closes" ]; then
        echo "not yet: none of your controls closes the gap you named. Add one that"
        echo "         changes who can modify what root runs, and say what it costs."
        exit 1
      fi

      echo "PASS — assets and entry points that exist, the boundary where invoice"
      echo "       reaches root, threats stated as capabilities, and controls that"
      echo "       admit what they cost."
---
