---
kind: lesson
title: "receipts broke the day AppArmor went to enforce"
description: |
  The hardening rollout moved the receipt renderer's AppArmor profile from
  complain to enforce, and every receipt since has been a 500. Someone has
  already proposed flipping it back. The profile is right about almost
  everything; the work is finding the one thing it is wrong about, from the
  denial the kernel logged, and allowing exactly that.
name: apparmor-denial
slug: apparmor-denial
createdAt: "2026-11-20"

sandbox:
  stack: linux-box
  service: box

# The box shares the Docker host's kernel, and only a kernel built with
# AppArmor can enforce a profile. macOS Docker VMs are built without it.
requires: [apparmor]

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      mountpoint -q /sys/kernel/security || mount -t securityfs securityfs /sys/kernel/security

      # ---- clean slate ---------------------------------------------------
      systemctl stop receipt-render.service 2>/dev/null || true
      systemctl reset-failed receipt-render.service 2>/dev/null || true
      if grep -q '^receipt-render ' /sys/kernel/security/apparmor/profiles; then
        echo 'profile receipt-render {}' | apparmor_parser -R
      fi
      rm -rf /usr/local/lib/receipt-render /etc/receipt-render \
             /var/lib/receipt-render /var/cache/receipt-render \
             /etc/apparmor.d/receipt-render /etc/apparmor.d/local/receipt-render \
             /etc/systemd/system/receipt-render.service /root/answers/denial.md
      id receipts >/dev/null 2>&1 || useradd --system --no-create-home \
          --shell /usr/sbin/nologin receipts
      install -d /root/answers

      # ---- the service ---------------------------------------------------
      # Release 2.4 moved the render cache from /var/cache to /var/lib. The
      # profile was written against 2.3. Failures are logged without the
      # errno, as the real service does, so the denial is the only evidence.
      install -d /usr/local/lib/receipt-render
      cat > /usr/local/lib/receipt-render/server.py <<'PY'
      import http.server, os, sys

      TEMPLATE = "/etc/receipt-render/template.txt"
      KEY = "/var/lib/receipt-render/signing.key"
      CACHE = "/var/lib/receipt-render/cache"  # 2.4: was /var/cache/receipt-render

      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              parts = self.path.strip("/").split("/")
              if len(parts) != 2 or parts[0] != "receipt" or not parts[1].isdigit():
                  self.send_error(404)
                  return
              rid = parts[1]
              try:
                  with open(TEMPLATE) as t, open(KEY) as k:
                      body = t.read().format(id=rid, sig=k.read().strip()[:12])
                  with open(os.path.join(CACHE, rid + ".txt"), "w") as c:
                      c.write(body)
              except Exception:
                  print(f"render failed for receipt {rid}", file=sys.stderr, flush=True)
                  self.send_error(500, "render failed")
                  return
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.end_headers()
              self.wfile.write(body.encode())

          def log_message(self, fmt, *args):
              pass

      http.server.HTTPServer(("127.0.0.1", 8088), Handler).serve_forever()
      PY

      install -d /etc/receipt-render
      printf 'RECEIPT #{id}\nsigned {sig}\n' > /etc/receipt-render/template.txt
      install -d -o receipts -g receipts -m 0750 /var/lib/receipt-render \
          /var/lib/receipt-render/cache /var/cache/receipt-render
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /var/lib/receipt-render/signing.key
      chown receipts:receipts /var/lib/receipt-render/signing.key
      chmod 0400 /var/lib/receipt-render/signing.key

      # ---- the profile, written for 2.3 ----------------------------------
      cat > /etc/apparmor.d/receipt-render <<'AA'
      abi <abi/4.0>,
      include <tunables/global>

      profile receipt-render flags=(attach_disconnected) {
        include <abstractions/base>
        include <abstractions/python>

        network inet stream,

        /usr/bin/python3* ix,
        /usr/local/lib/receipt-render/** r,
        /etc/receipt-render/** r,
        /var/lib/receipt-render/signing.key r,
        /var/cache/receipt-render/** rw,
      }
      AA
      apparmor_parser -r /etc/apparmor.d/receipt-render

      cat > /etc/systemd/system/receipt-render.service <<'U'
      [Unit]
      Description=Receipt renderer

      [Service]
      User=receipts
      AppArmorProfile=receipt-render
      ExecStart=/usr/bin/python3 /usr/local/lib/receipt-render/server.py
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target
      U
      systemctl daemon-reload
      systemctl enable --now receipt-render.service

      for _ in $(seq 50); do
        curl -s -o /dev/null http://127.0.0.1:8088/ && break
        sleep 0.2
      done

      # The scenario is only honest if the student can see the denial. Without
      # auditd the kernel rate-limits audit lines into dmesg, and the burst from
      # loading the profile can swallow the first one, so ask until it shows.
      seen=
      for i in $(seq 15); do
        code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088/receipt/$((1000 + i)))
        if [ "$code" != 500 ]; then
          echo "scenario did not break: GET /receipt/$((1000 + i)) returned $code, not 500" >&2
          exit 1
        fi
        sleep 1
        if dmesg | grep 'apparmor="DENIED"' | grep -q 'name="/var/lib/receipt-render/cache/'; then
          seen=1
          break
        fi
      done
      if [ -z "$seen" ]; then
        echo "the kernel's AppArmor denial is not visible in dmesg from the box." >&2
        echo "If the host runs auditd, denials go to its audit log instead;" >&2
        echo "this lesson needs them in the kernel log." >&2
        exit 1
      fi

      echo "scenario ready — every receipt from receipt-render.service is a 500 since enforce"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      set -e
      mountpoint -q /sys/kernel/security || mount -t securityfs securityfs /sys/kernel/security

      prof=/etc/apparmor.d/receipt-render
      ans=/root/answers/denial.md
      loaded=/sys/kernel/security/apparmor/profiles

      # ---- the profile is loaded, from the file, in enforce --------------
      # Grading the file, not only the kernel: a profile fixed in the kernel
      # alone is gone at the next reload or reboot.
      if [ ! -f "$prof" ]; then
        echo "not yet: $prof is gone. The fix is in the profile, not in removing it."
        exit 1
      fi
      if ! err=$(apparmor_parser -r "$prof" 2>&1); then
        echo "not yet: $prof does not load:"
        printf '%s\n' "$err" | head -n 4 | sed 's/^/         /'
        exit 1
      fi
      mode=$(sed -n 's/^receipt-render (\(.*\))$/\1/p' "$loaded")
      if [ "$mode" != enforce ]; then
        echo "not yet: receipt-render is loaded in ${mode:-no} mode. Complain mode"
        echo "         logs what it would deny and denies nothing — it is the state"
        echo "         the hardening rollout moved away from. Enforce, and fix the"
        echo "         rule that is missing."
        exit 1
      fi

      # ---- the service runs under it -------------------------------------
      systemctl restart receipt-render.service
      for _ in $(seq 50); do
        curl -s -o /dev/null http://127.0.0.1:8088/ && break
        sleep 0.2
      done
      pid=$(systemctl show -p MainPID --value receipt-render.service)
      if [ "${pid:-0}" = 0 ]; then
        echo "not yet: receipt-render.service is not running:"
        systemctl status receipt-render.service --no-pager 2>&1 | tail -n 4 | sed 's/^/         /'
        exit 1
      fi
      label=$(cat /proc/"$pid"/attr/apparmor/current 2>/dev/null || cat /proc/"$pid"/attr/current)
      if [ "$label" != "receipt-render (enforce)" ]; then
        echo "not yet: the service runs as '$label', not under receipt-render in"
        echo "         enforce. Leave AppArmorProfile= in the unit; a service that"
        echo "         is not confined is not protected by the profile."
        exit 1
      fi

      # ---- it renders ----------------------------------------------------
      rid=$(( $(od -An -tu2 -N2 /dev/urandom) + 20000 ))
      code=$(curl -s -o /tmp/receipt.$$ -w '%{http_code}' http://127.0.0.1:8088/receipt/$rid || true)
      if [ "$code" != 200 ] || ! grep -q "RECEIPT #$rid" /tmp/receipt.$$; then
        rm -f /tmp/receipt.$$
        echo "not yet: GET /receipt/$rid returned $code. The profile still denies"
        echo "         something the service needs — the newest denial in dmesg says what."
        exit 1
      fi
      rm -f /tmp/receipt.$$
      if [ ! -f /var/lib/receipt-render/cache/$rid.txt ]; then
        echo "not yet: the receipt rendered but was not cached in"
        echo "         /var/lib/receipt-render/cache. Leave the service's code alone."
        exit 1
      fi

      # ---- and it is still a guard ---------------------------------------
      # Run as root so file permissions cannot stop anything: only the
      # profile can.
      # Exit 3 is a permission error and nothing else, so a probe that dies
      # for another reason cannot pass for a denial. Probes run as the
      # service's user, on paths its file permissions allow, so only the
      # profile can refuse them.
      probe() {
        runuser -u "${2:-receipts}" -- aa-exec -p receipt-render -- python3 -c "
      try:
          $1
      except PermissionError:
          raise SystemExit(3)" 2>/dev/null
      }
      denies() {
        local rc=0
        probe "$@" || rc=$?
        [ "$rc" = 3 ]
      }
      if ! probe 'open("/etc/receipt-render/template.txt").read()'; then
        echo "not yet: under receipt-render a process cannot even read its own"
        echo "         template. Keep the profile's existing rules; add to them."
        exit 1
      fi
      if ! denies 'open("/etc/shadow").read()' root; then
        echo "not yet: under receipt-render a process can read /etc/shadow. The"
        echo "         profile has been widened past the service's needs; allow"
        echo "         the one path the denial names."
        exit 1
      fi
      planted=/var/lib/receipt-render/signing.key.new
      rm -f "$planted"
      if ! denies "open('$planted','w')"; then
        rm -f "$planted"
        echo "not yet: under receipt-render the service can create files next to"
        echo "         its signing key. It writes only its cache; a rule covering"
        echo "         all of /var/lib/receipt-render grants more than the denial"
        echo "         asked for."
        exit 1
      fi
      if ! denies 'open("/etc/receipt-render/template.txt","a")' root; then
        echo "not yet: under receipt-render a process can write its own template."
        echo "         Allow writes to the cache only."
        exit 1
      fi

      # ---- the denial, quoted --------------------------------------------
      if [ ! -s "$ans" ]; then
        echo "not yet: the profile is fixed. Now paste the denial that told you"
        echo "         what to allow into /root/answers/denial.md."
        exit 1
      fi
      if grep -q 'apparmor="ALLOWED"' "$ans" && ! grep -q 'apparmor="DENIED"' "$ans"; then
        echo "not yet: $ans quotes an ALLOWED line — what complain mode logs."
        echo "         Quote the DENIED line enforce logged for the failing request."
        exit 1
      fi
      if ! grep 'apparmor="DENIED"' "$ans" | grep 'profile="receipt-render"' \
           | grep -q 'name="/var/lib/receipt-render/cache/'; then
        echo "not yet: $ans does not quote the denial that broke rendering — a"
        echo "         DENIED line for profile receipt-render naming the file it"
        echo "         was refused. Copy it from dmesg as logged."
        exit 1
      fi

      echo "PASS — receipt-render is in enforce, the service renders and caches,"
      echo "       and the profile still refuses the shadow file, the signing key"
      echo "       and its own template."
