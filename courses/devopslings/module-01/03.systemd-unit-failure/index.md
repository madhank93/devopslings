---
kind: lesson
title: "checkout-api won't start and the exit code tells you nothing"
description: |
  A service is in `failed` state after a config change. `systemctl status`
  gives you an exit code and not much else. Learn to get the actual cause out
  of the journal — and why the service refuses to start again even after you
  fix it.
name: systemd-unit-failure
slug: systemd-unit-failure
createdAt: "2026-07-31"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      install -d /etc/checkout-api

      cat > /usr/local/bin/checkout-api <<'PY'
      #!/usr/bin/env python3
      import os, sys, time

      # Fail loudly and specifically. The whole lesson is that this message
      # exists and is reachable — it just isn't in `systemctl status`.
      url = os.environ.get("DATABASE_URL")
      if not url:
          print("FATAL: DATABASE_URL is not set — refusing to start", file=sys.stderr)
          sys.exit(1)
      if not url.startswith("postgres://"):
          print(f"FATAL: DATABASE_URL must be a postgres:// URL, got {url!r}", file=sys.stderr)
          sys.exit(1)

      os.makedirs("/run/checkout-api", exist_ok=True)
      with open("/run/checkout-api/ready", "w") as f:
          f.write(url)
      print(f"checkout-api listening on :8080, db={url}")
      while True:
          time.sleep(3600)
      PY
      chmod +x /usr/local/bin/checkout-api

      # The dash on EnvironmentFile makes the file optional. systemd starts the
      # unit happily without it and never mentions that it was missing — the
      # complaint comes from the application instead, which is why the journal
      # matters more than the unit state here.
      cat > /etc/systemd/system/checkout-api.service <<'UNIT'
      [Unit]
      Description=Checkout API
      After=network.target

      [Service]
      Type=simple
      EnvironmentFile=-/etc/checkout-api/env
      ExecStart=/usr/local/bin/checkout-api
      Restart=on-failure
      RestartSec=1
      StartLimitBurst=3
      StartLimitIntervalSec=30

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable checkout-api.service >/dev/null 2>&1
      systemctl start checkout-api.service >/dev/null 2>&1 || true

      # Let it exhaust its restart budget and settle into `failed`, so the
      # student meets it in the state a real box would be in by the time anyone
      # looked.
      for _ in $(seq 30); do
        state=$(systemctl is-failed checkout-api.service 2>/dev/null || true)
        [ "$state" = "failed" ] && break
        sleep 1
      done
      echo "scenario ready — checkout-api.service is ${state:-not running}"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 90
    run: |
      if ! systemctl is-active --quiet checkout-api.service; then
        state=$(systemctl is-active checkout-api.service 2>/dev/null || true)
        echo "not yet: checkout-api.service is '${state:-inactive}', not active"
        exit 1
      fi

      # The app only writes this after it validated its config, so its presence
      # is proof the service actually came up rather than merely being
      # "started".
      if [ ! -f /run/checkout-api/ready ]; then
        echo "not yet: the service is active but never became ready"
        exit 1
      fi

      url=$(cat /run/checkout-api/ready)
      case "$url" in
        postgres://*) ;;
        *) echo "not yet: DATABASE_URL is '$url' — that is not a postgres:// URL"; exit 1 ;;
      esac

      # The fix has to survive a reboot. Setting the variable in your shell, or
      # passing it with `systemd-run`, gets the service up exactly once.
      if [ ! -s /etc/checkout-api/env ]; then
        echo "not yet: /etc/checkout-api/env is missing or empty — the unit reads its config from there, so this fix won't survive a restart"
        exit 1
      fi

      # Prove it: restart from scratch and require it to come back on its own.
      rm -f /run/checkout-api/ready
      systemctl restart checkout-api.service
      for _ in $(seq 15); do
        [ -f /run/checkout-api/ready ] && break
        sleep 1
      done
      if [ ! -f /run/checkout-api/ready ]; then
        echo "not yet: the service did not come back after a restart"
        exit 1
      fi

      if ! systemctl is-enabled --quiet checkout-api.service; then
        echo "not yet: checkout-api.service is not enabled — it won't come up on boot"
        exit 1
      fi

      echo "PASS — checkout-api is up, configured from /etc/checkout-api/env, and survives a restart."
---
