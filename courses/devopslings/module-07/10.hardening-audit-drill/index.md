---
kind: lesson
title: "the compliance scan failed the reports host, and it will not say which line"
description: |
  The pre-audit scan of box reports one finding. That is the whole ticket, every
  time — because the finding is drawn at random from five, each a different way
  a host drifts from its written baseline: a sudo grant wider than the runbook,
  a stray setuid bit, a world-readable credential, a service back on root, an
  extra sshd port. The drill is the audit order, and restoring the baseline
  without breaking what it protects.
name: hardening-audit-drill
slug: hardening-audit-drill
createdAt: "2026-10-07"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop reports.service 2>/dev/null || true
      systemctl reset-failed reports.service 2>/dev/null || true
      rm -rf /etc/systemd/system/reports.service.d /etc/systemd/system/reports.service \
             /opt/reports /etc/reports /var/lib/audit-drill /root/answers/triage.md
      rm -f /etc/sudoers.d/reports /usr/local/bin/reports-fetch \
            /etc/ssh/sshd_config.d/60-reports-debug.conf
      id reports >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin reports
      id reportop >/dev/null 2>&1 || useradd -m -s /bin/bash reportop
      install -d /opt/reports /etc/reports /root/answers
      install -d -m 0700 /var/lib/audit-drill

      # Package-owned setuid binaries a previous attempt may have stripped.
      for b in /usr/bin/passwd /usr/bin/sudo; do
        [ -f "$b" ] && chown root:root "$b" && chmod 4755 "$b"
      done
      # The herring: the newest setuid file on the box, freshly touched by a
      # package update, and exactly what dpkg shipped.
      touch -d '-40 minutes' /usr/bin/passwd

      # ---- the reports service -----------------------------------------
      openssl rand -hex 24 | sed 's/^/reportsdb:/' > /etc/reports/db.key
      chown root:reports /etc/reports/db.key
      chmod 0640 /etc/reports/db.key
      sha256sum /etc/reports/db.key | awk '{print $1}' > /var/lib/audit-drill/key

      cat > /opt/reports/reports.py <<'PY'
      import hashlib
      import http.server

      KEY = "/etc/reports/db.key"


      class Reports(http.server.BaseHTTPRequestHandler):
          def reply(self, code, body):
              body = body.encode()
              self.send_response(code)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              if self.path != "/report":
                  self.reply(200, "reports up\n")
                  return
              # The credential is read per request, so a report proves the
              # service user can read it now, not merely at start.
              try:
                  with open(KEY, "rb") as f:
                      fp = hashlib.sha256(f.read()).hexdigest()[:12]
              except OSError as e:
                  print(f"reports: cannot read {KEY}: {e}", flush=True)
                  self.reply(500, "cannot read credential\n")
                  return
              self.reply(200, f"report ok db={fp}\n")

          def log_message(self, *args):
              pass


      class Server(http.server.ThreadingHTTPServer):
          allow_reuse_address = True


      Server(("127.0.0.1", 8090), Reports).serve_forever()
      PY

      cat > /etc/systemd/system/reports.service <<'UNIT'
      [Unit]
      Description=reports API
      After=network.target

      [Service]
      User=reports
      Group=reports
      ExecStart=/usr/bin/python3 /opt/reports/reports.py
      Restart=on-failure
      RestartSec=1

      [Install]
      WantedBy=multi-user.target
      UNIT

      # The runbook's client, run by anyone who needs a report.
      install -m 0755 -o root -g root /usr/bin/curl /usr/local/bin/reports-fetch

      printf '%s\n' \
        '# reports runbook: the operator restarts the service after a config push.' \
        'reportop ALL=(root) NOPASSWD: /usr/bin/systemctl restart reports.service' \
        > /etc/sudoers.d/reports
      chmod 0440 /etc/sudoers.d/reports
      visudo -cf /etc/sudoers.d/reports >/dev/null

      # ---- sshd, as the baseline has it --------------------------------
      systemctl mask ssh.socket >/dev/null 2>&1 || true
      ssh-keygen -A >/dev/null 2>&1
      printf '%s\n' \
        'Include /etc/ssh/sshd_config.d/*.conf' \
        'Port 22' \
        'PermitRootLogin no' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PubkeyAuthentication yes' \
        'Subsystem sftp /usr/lib/openssh/sftp-server' \
        > /etc/ssh/sshd_config
      install -d /etc/ssh/sshd_config.d
      # sshd -t needs the privsep dir, which only exists while ssh.service runs.
      install -d -m 0755 /run/sshd
      sshd -t

      cat > /etc/reports/baseline.md <<'BASE'
      # reports host — security baseline

      The compliance scan diffs this box against this file. Anything that does
      not match is a finding. Every item protects something that must keep
      working; restoring an item never means removing what it describes.

      1. sudo — reportop may run exactly one command as root, without a
         password, and nothing else from any file under /etc/sudoers.d:
             /usr/bin/systemctl restart reports.service

      2. setuid — the only setuid files on the box are ones a Debian package
         installed (dpkg -S names the package). /usr/local/bin/reports-fetch is
         an ordinary program, mode 0755 root:root, that any user runs:
             reports-fetch -s http://127.0.0.1:8090/report

      3. credentials — /etc/reports/db.key is owner root, group reports, mode
         0640. The reports service reads it on every request.

      4. service — reports.service is enabled and running, as User=reports and
         Group=reports. It listens on 127.0.0.1:8090 only.

      5. listeners — sshd (ssh.service) is running and listens on port 22, and
         on no other port.
      BASE
      chmod 0644 /etc/reports/baseline.md

      systemctl daemon-reload
      systemctl enable ssh.service reports.service >/dev/null 2>&1
      systemctl reset-failed ssh.service reports.service >/dev/null 2>&1 || true
      systemctl restart ssh.service reports.service

      probe() {
        runuser -u reportop -- /usr/local/bin/reports-fetch -sS -m 5 http://127.0.0.1:8090/report 2>/dev/null | grep -q 'report ok'
      }

      # Healthy and on baseline before one thing drifts, so a scenario that
      # failed to come up cannot be mistaken for the seeded finding.
      ok=""
      for _ in $(seq 1 40); do
        if probe && ss -ltnH 'sport = :22' | grep -q .; then ok=yes; break; fi
        sleep 0.25
      done
      if [ -z "$ok" ]; then
        echo "the scenario did not come up healthy before the finding was seeded"
        exit 1
      fi

      # ---- seed one finding --------------------------------------------
      faults="sudo setuid key root port"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      case "$fault" in
        sudo)
          # Widened during an incident "so the operator is not blocked", and
          # never narrowed again: every systemctl verb on every unit.
          sed -i 's|^reportop .*|reportop ALL=(root) NOPASSWD: /usr/bin/systemctl|' /etc/sudoers.d/reports
          visudo -cf /etc/sudoers.d/reports >/dev/null
          ;;
        setuid)
          chmod 4755 /usr/local/bin/reports-fetch
          ;;
        key)
          chmod 0644 /etc/reports/db.key
          ;;
        root)
          install -d /etc/systemd/system/reports.service.d
          printf '%s\n' '# Debugging the export job: run with full access for now.' \
            '[Service]' 'User=root' 'Group=root' \
            > /etc/systemd/system/reports.service.d/10-debug.conf
          systemctl daemon-reload
          systemctl restart reports.service
          ;;
        port)
          printf '%s\n' '# Second listener for the vendor support session, INC-2291.' 'Port 2222' \
            > /etc/ssh/sshd_config.d/60-reports-debug.conf
          sshd -t
          systemctl reload ssh.service
          for _ in $(seq 1 40); do
            ss -ltnH 'sport = :2222' | grep -q . && break
            sleep 0.25
          done
          ;;
      esac

      # Every finding is configuration drift; the service still works.
      ok=""
      for _ in $(seq 1 40); do
        if probe; then ok=yes; break; fi
        sleep 0.25
      done
      if [ -z "$ok" ]; then
        echo "the $fault finding was seeded and broke the reports service"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # that the box matches its baseline again and the service still works.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > /var/lib/audit-drill/state
      chmod 600 /var/lib/audit-drill/state /var/lib/audit-drill/key

      cat > /root/questions.txt <<'Q'
      The pre-audit compliance scan of the box failed. It reports one finding
      against the reports service host. Fix the finding without breaking the
      service.

      The baseline the scan checks against is /etc/reports/baseline.md. Every
      fix is "make the box match the baseline" — and every item on it protects
      something that has to keep working:

        reports-fetch -s http://127.0.0.1:8090/report     # any user, any time
        sudo systemctl restart reports.service            # as reportop
        ssh to port 22

      The finding is drawn at random from five. Run the lesson again and it
      moves.

      1. Find the one item the box does not match, and restore it.

      2. Write /root/answers/triage.md, three lines:

           cause:     <what did not match the baseline, in a few words>
           evidence:  <the audit command that showed it>
           detection: <the check that would flag it on every host>
      Q

      echo "scenario ready — one finding seeded against the baseline"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      digest=$(cat /var/lib/audit-drill/state 2>/dev/null || true)
      fault=""
      for cand in sudo setuid key root port; do
        h=$(printf '%s' "$cand" | sha256sum | awk '{print $1}')
        [ "$h" = "$digest" ] && fault="$cand"
      done
      if [ -z "$fault" ]; then
        echo "not yet: /var/lib/audit-drill/state does not name a seeded finding."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi

      report() {
        runuser -u reportop -- /usr/local/bin/reports-fetch -sS -m 5 http://127.0.0.1:8090/report 2>&1 || true
      }
      wait_report() {
        for _ in $(seq 1 30); do
          report | grep -q 'report ok' && return 0
          sleep 0.25
        done
        return 1
      }

      # ---- the accounts the baseline names -------------------------------
      for u in reports reportop; do
        if ! id "$u" >/dev/null 2>&1; then
          echo "not yet: the user $u no longer exists. The baseline names it; the"
          echo "         finding was about what $u is allowed, not that it exists."
          echo "         Start the lesson again to get it back."
          exit 1
        fi
      done

      # ---- 4. the service: enabled, running, as reports --------------------
      if [ "$(systemctl is-enabled reports.service 2>/dev/null || true)" != enabled ]; then
        echo "not yet: reports.service is $(systemctl is-enabled reports.service 2>/dev/null || true),"
        echo "         not enabled. The baseline keeps it enabled and running; a"
        echo "         service that is off has no findings and does no work."
        exit 1
      fi
      unit_user=$(systemctl show -p User --value reports.service 2>/dev/null || true)
      if [ "$unit_user" != reports ]; then
        echo "not yet: reports.service is configured to run as '${unit_user:-root}'"
        echo "         (systemctl show -p User). The baseline says User=reports."
        echo "         systemctl cat reports.service lists every file that sets it;"
        echo "         systemd sees an edited or removed file after daemon-reload."
        exit 1
      fi
      if ! systemctl is-active --quiet reports.service; then
        echo "not yet: reports.service is $(systemctl is-active reports.service 2>/dev/null || true)."
        echo "         The baseline keeps it running; journalctl -u reports.service"
        echo "         says why it is not."
        exit 1
      fi
      pid=$(systemctl show -p MainPID --value reports.service 2>/dev/null || true)
      run_user=$(ps -o user= -p "${pid:-0}" 2>/dev/null | tr -d ' ' || true)
      if [ "$run_user" != reports ]; then
        echo "not yet: the unit says User=reports, but its running process (pid"
        echo "         ${pid:-?}) is '${run_user:-unknown}'. systemd applies User= when it"
        echo "         starts the process: daemon-reload, then restart reports.service."
        exit 1
      fi

      # ---- the service still does its job ---------------------------------
      if ! wait_report; then
        got=$(report | head -1 || true)
        key=/etc/reports/db.key
        rf=/usr/local/bin/reports-fetch
        echo "not yet: reports-fetch -s http://127.0.0.1:8090/report answered: ${got:-nothing}"
        if [ ! -f "$rf" ]; then
          echo "         $rf is gone. The runbook uses it; the finding is a bit on"
          echo "         the file, so remove the bit and keep the program."
        elif ! runuser -u reportop -- test -x "$rf"; then
          echo "         reportop cannot run $rf ($(stat -c '%A %U:%G' "$rf"))."
          echo "         The baseline is 0755 root:root: every user runs it, no"
          echo "         user gains anything by running it."
        elif [ ! -e "$key" ]; then
          echo "         $key is gone. The finding was about who can read it;"
          echo "         the service reads it on every request."
        elif ! runuser -u reports -- test -r "$key"; then
          echo "         The reports user cannot read $key ($(stat -c '%U:%G %a' "$key"))."
          echo "         The baseline is root:reports 0640: the owner writes it, the"
          echo "         service's group reads it, and nobody else does."
        else
          echo "         journalctl -u reports.service has what the service said."
        fi
        exit 1
      fi
      laddr=$(ss -ltnH 'sport = :8090' 2>/dev/null | awk '{print $4}' | sort -u | paste -sd' ' || true)
      if [ "$laddr" != "127.0.0.1:8090" ]; then
        echo "not yet: port 8090 is listening on '${laddr:-nothing}'. The baseline is"
        echo "         127.0.0.1:8090 only."
        exit 1
      fi

      # ---- 3. the credential ------------------------------------------------
      key=/etc/reports/db.key
      if [ "$(sha256sum "$key" | awk '{print $1}')" != "$(cat /var/lib/audit-drill/key)" ]; then
        echo "not yet: $key has different contents from the one the service was"
        echo "         given. Its permissions were the finding, never its value."
        exit 1
      fi
      kmode=$(stat -c '%a' "$key")
      kown=$(stat -c '%U:%G' "$key")
      if [ "$kown" != root:reports ] || [ $(( 0$kmode & 07 )) -ne 0 ]; then
        echo "not yet: $key is $kown, mode $kmode. The baseline is root:reports 0640:"
        echo "         readable by the service's group, by nobody outside it."
        exit 1
      fi

      # ---- 2. setuid ------------------------------------------------------
      rf=/usr/local/bin/reports-fetch
      if [ ! -f "$rf" ]; then
        echo "not yet: $rf is gone. The runbook uses it; the finding is a bit on"
        echo "         the file, so remove the bit and keep the program."
        exit 1
      fi
      if [ "$(sha256sum "$rf" | awk '{print $1}')" != "$(sha256sum /usr/bin/curl | awk '{print $1}')" ]; then
        echo "not yet: $rf is not the program that was installed there. Only its"
        echo "         mode was a finding."
        exit 1
      fi
      if [ -u "$rf" ] || [ -g "$rf" ]; then
        echo "not yet: $rf is still $(stat -c '%A %U:%G' "$rf"). The baseline is"
        echo "         0755 root:root: no package installed it, so it gets no setuid bit."
        exit 1
      fi
      unowned=""
      for f in $(find / -xdev -perm -4000 -type f 2>/dev/null || true); do
        dpkg -S "$f" >/dev/null 2>&1 || unowned="$unowned $f"
      done
      if [ -n "$unowned" ]; then
        echo "not yet: setuid files that no package installed:$unowned"
        echo "         The baseline allows setuid only on what dpkg -S can name."
        exit 1
      fi

      # ---- the herring ----------------------------------------------------
      pw=/usr/bin/passwd
      want=$(awk '$2=="usr/bin/passwd"{print $1}' /var/lib/dpkg/info/passwd.md5sums 2>/dev/null || true)
      if [ ! -f "$pw" ] || [ "$(md5sum "$pw" | awk '{print $1}')" != "$want" ]; then
        echo "not yet: $pw is missing or no longer what the passwd package shipped."
        echo "         It was the newest setuid file on the box, and dpkg owns it."
        exit 1
      fi
      if [ "$(stat -c '%a %U' "$pw")" != "4755 root" ]; then
        echo "not yet: $pw is $(stat -c '%A %U:%G' "$pw"); it ships 4755 root."
        echo "         It was the newest setuid file in the scan, and the passwd"
        echo "         package owns it (dpkg -S $pw). Users change their own"
        echo "         password through it. Put it back: chmod 4755 $pw"
        exit 1
      fi
      if [ ! -u /usr/bin/sudo ]; then
        echo "not yet: /usr/bin/sudo has lost its setuid bit; the sudo package ships"
        echo "         it setuid. chmod 4755 /usr/bin/sudo"
        exit 1
      fi

      # ---- 1. sudo ----------------------------------------------------------
      if ! visudo -c >/dev/null 2>&1; then
        echo "not yet: visudo -c rejects the sudoers configuration:"
        visudo -c 2>&1 | grep -v 'parsed OK' | head -3 | sed 's/^/         /' || true
        exit 1
      fi
      want_cmd='/usr/bin/systemctl restart reports.service'
      grants=$(sudo -l -U reportop 2>/dev/null \
        | sed -n '/may run the following commands/,$p' | sed 1d \
        | sed -E 's/^[[:space:]]*\([^)]*\)[[:space:]]*//; s/([A-Z_]+:[[:space:]]*)+//' \
        | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true)
      extra=$(printf '%s\n' "$grants" | grep -vxF "$want_cmd" | grep -v '^$' || true)
      if [ -n "$extra" ]; then
        echo "not yet: sudo -l -U reportop still grants more than the baseline:"
        printf '%s\n' "$extra" | sed 's/^/         /'
        echo "         The baseline is exactly: $want_cmd"
        exit 1
      fi
      if ! printf '%s\n' "$grants" | grep -qxF "$want_cmd"; then
        echo "not yet: reportop has no sudo grant for '$want_cmd'."
        echo "         The runbook needs that one command; the finding was anything"
        echo "         beyond it. Grant exactly it in /etc/sudoers.d/reports."
        exit 1
      fi
      before=$(systemctl show -p MainPID --value reports.service 2>/dev/null || true)
      if ! sudo -u reportop sudo -n $want_cmd >/dev/null 2>&1; then
        echo "not yet: sudo -l lists the grant, but reportop's restart failed:"
        sudo -u reportop sudo -n $want_cmd 2>&1 | head -2 | sed 's/^/         /' || true
        exit 1
      fi
      after=$(systemctl show -p MainPID --value reports.service 2>/dev/null || true)
      if [ "$before" = "$after" ] || ! wait_report; then
        echo "not yet: reportop's restart of reports.service did not bring up a new,"
        echo "         working process. journalctl -u reports.service says why."
        exit 1
      fi

      # ---- 5. sshd listeners ------------------------------------------------
      if ! systemctl is-active --quiet ssh.service; then
        echo "not yet: ssh.service is $(systemctl is-active ssh.service 2>/dev/null || true). The"
        echo "         baseline keeps sshd on port 22; the finding is a listener"
        echo "         beyond that, not sshd itself."
        exit 1
      fi
      cfg_ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | paste -sd' ' || true)
      if [ "$cfg_ports" != 22 ]; then
        echo "not yet: sshd -T says sshd is configured for port(s): ${cfg_ports:-none}."
        echo "         The baseline is port 22 and nothing else. sshd -T resolves the"
        echo "         drop-ins under /etc/ssh/sshd_config.d too."
        exit 1
      fi
      live=""
      for _ in $(seq 1 20); do
        spid=$(systemctl show -p MainPID --value ssh.service 2>/dev/null || true)
        live=$(ss -ltnpH 2>/dev/null | grep "pid=${spid:-0}," | awk '{print $4}' | sed 's/.*://' | sort -un | paste -sd' ' || true)
        [ "$live" = 22 ] && break
        sleep 0.25
      done
      if [ "$live" != 22 ]; then
        echo "not yet: the config says port 22, but the running sshd listens on:"
        echo "         ${live:-nothing}. sshd reads its config when it starts or"
        echo "         reloads: sshd -t, then systemctl reload ssh."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: the box matches its baseline. /root/answers/triage.md is"
        echo "         missing or empty: three lines, cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)
      # Matching uses the lowercased text; messages quote the student's own line.
      said() { sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//Ip" /root/answers/triage.md | awk 'NF{print;f=1;exit} END{if(!f)print "nothing"}'; }

      case "$fault" in
        sudo)
          what="/etc/sudoers.d/reports granted reportop all of /usr/bin/systemctl, not the one restart"
          c_re='\b(sudo|sudoers|nopasswd|grants?|granted|systemctl)\b'
          e_re='\bsudo\b[^|]*-l\b|\bvisudo\b|/etc/sudoers'
          e_say="sudo -l -U reportop, against the baseline's one command"
          d_re='\b(sudo|sudoers|visudo)\b'
          d_say="sudo -l -U per operator account, diffed against its allowed list" ;;
        setuid)
          what="/usr/local/bin/reports-fetch was setuid (4755), and no package installed it"
          c_re='\b(setuid|suid|set-uid|4755|4000|u\+s)\b'
          e_re='-perm|\bfind\b|\bstat\b|\bls\b|\bdpkg\b'
          e_say="find / -xdev -perm -4000, then dpkg -S on each result"
          d_re='\b(setuid|suid|perm|4000|dpkg|package|unowned)\b'
          d_say="setuid files (find -perm -4000) that dpkg -S cannot name" ;;
        key)
          what="/etc/reports/db.key was mode 0644, readable by every user"
          c_re='\b(world[- ]?readable|readable|0?644|permissions?|mode|o\+r|others|everyone)\b'
          e_re='\bstat\b|\bls\b|\bfind\b|\bnamei\b|\bgetfacl\b'
          e_say="stat -c '%U:%G %a' /etc/reports/db.key"
          d_re='\b(modes?|perms?|permissions?|world[- ]?readable|readable|stat|0?640|0?644|o\+r|others)\b'
          d_say="credential files whose mode grants anything to other (find -perm /o+r)" ;;
        root)
          what="a drop-in, reports.service.d/10-debug.conf, set User=root"
          c_re='\b(root|user|uid)\b'
          e_re='\bsystemctl\b[^|]*\b(show|cat|status)\b|\bps\b|/proc/[^ ]*/status|\bpgrep\b|\btop\b'
          e_say="systemctl show -p User reports.service, or ps -o user= on its MainPID"
          d_re='\b(user|root|uid)\b'
          d_say="services whose User= (systemctl show -p User) is empty or root" ;;
        port)
          what="an sshd drop-in, 60-reports-debug.conf, added Port 2222"
          c_re='\b(ports?|2222|listen|listens|listening|listeners?|sshd|ssh)\b'
          e_re='\bss\b|\bnetstat\b|\blsof\b|\bsshd -t\b|\bnmap\b'
          e_say="ss -ltnp, or sshd -T | grep ^port"
          d_re='\b(ports?|listen|listening|listeners?|ss|sshd)\b'
          d_say="listening sockets (ss -ltn) diffed against the baseline's list" ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '$(said cause)', and the box matches its"
        echo "         baseline, so something was restored. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq -- "$e_re"; then
        fail=1
        echo "not yet: evidence says '$(said evidence)'. For this finding the audit"
        echo "         command is $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '$(said detection)'. Name the check that would"
        echo "         flag this on every host: $d_say."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the $fault finding is restored to the baseline; reports still"
      echo "       answers as reports, reportop can still restart it, sshd is on 22,"
      echo "       and /usr/bin/passwd kept the setuid bit it ships with."
---
