---
kind: lesson
title: "green dashboards, nobody can log in"
description: |
  Every metric the login service exports is green and its error rate is zero,
  and customers cannot sign in. The service counts the requests it answers,
  and it answered every one with a 200. Watch it from where the customer
  stands: probe the page, check what it says, and check the certificate it
  is served with.
name: blackbox-probe
slug: blackbox-probe
createdAt: "2026-11-22"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      # obs-reset removed /obs/portal; a fresh start makes a new certificate.
      app_up portal; app_restart portal
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: portal
          static_configs:
            - targets: ["portal:9101"]
      YML
      cat > /obs/prometheus/rules/portal.yml <<'YML'
      groups:
        - name: portal
          rules:
            - alert: PortalErrors
              expr: sum(rate(portal_http_requests_total{code!="200"}[1m])) > 0
              for: 30s
              labels:
                severity: critical
              annotations:
                summary: portal is answering requests with errors
      YML
      chmod a+r /obs/prometheus/rules/portal.yml
      touch /obs/run/portal.fault
      obs-reload >/dev/null
      for _ in $(seq 1 30); do [ -e /obs/portal/tls.crt ] && curl -sk -o /dev/null https://portal:8443/login && break; sleep 1; done
      for _ in $(seq 1 20); do curl -sk -o /dev/null https://portal:8443/login; done
      echo "scenario ready: portal serves the login page at https://portal:8443/login."
      echo "Its own metrics (job=\"portal\") and its alert (/obs/prometheus/rules/portal.yml) say"
      echo "all is well. Try the page yourself: curl -sk https://portal:8443/login"

  verify_done:
    timeout_seconds: 600
    run: |
      . /usr/local/lib/obs.sh
      cert() {
        local d; d=$(mktemp -d)
        openssl req -x509 -newkey rsa:2048 -nodes -days "$1" -subj /CN=portal \
          -addext subjectAltName=DNS:portal -keyout "$d/k" -out "$d/c" 2>/dev/null
        chmod a+r "$d/k" "$d/c"
        mv "$d/k" /obs/portal/tls.key; mv "$d/c" /obs/portal/tls.crt; rmdir "$d"
      }
      cleanup() {
        rm -f /obs/run/portal.fault
        if [ -n "${short_cert:-}" ]; then cert 365; fi
      }
      trap cleanup EXIT
      rm -f /obs/run/portal.fault
      app_up portal
      [ -e /obs/portal/tls.crt ] || app_restart portal
      for _ in $(seq 1 30); do [ -e /obs/portal/tls.crt ] && break; sleep 1; done
      cert 365
      obs_require_loaded || exit 1
      bb=$(curl -s --max-time 10 "$BLACKBOX/metrics" || true)
      if ! grep -q '^blackbox_exporter_config_last_reload_successful 1' <<<"$bb"; then
        echo "not yet: blackbox_exporter rejected /obs/blackbox/blackbox.yml and is still running the"
        echo "one before. Run obs-reload to see the error."
        exit 1
      fi
      loaded=$(awk '/^blackbox_exporter_config_last_reload_success_timestamp_seconds /{printf "%d", $2}' <<<"$bb")
      if [ "$(newest_mtime /obs/blackbox/blackbox.yml)" -gt "${loaded:-0}" ]; then
        echo "not yet: blackbox.yml changed after blackbox_exporter last loaded it. Run obs-reload."
        exit 1
      fi

      # The probe: a target scraped through blackbox_exporter whose probe
      # target is portal. A target appears a few seconds after a reload.
      url=
      for _ in $(seq 1 20); do
        url=$(curl -s --max-time 10 "$PROM/api/v1/targets?state=active" | jq -r '[.data.activeTargets[]
          | select(.scrapeUrl | test("/probe\\?")) | select(.scrapeUrl | test("portal"))][0].scrapeUrl // empty' 2>/dev/null || true)
        [ -n "$url" ] && break
        sleep 1
      done
      if [ -z "$url" ]; then
        echo "not yet: Prometheus scrapes no blackbox_exporter probe of portal. A probe is a scrape"
        echo "of blackbox:9115/probe with the module and the target as URL parameters; the"
        echo "relabelling in the lesson turns a target address into those parameters."
        exit 1
      fi
      job=$(curl -s --max-time 10 "$PROM/api/v1/targets?state=active" | jq -r --arg u "$url" \
        '[.data.activeTargets[] | select(.scrapeUrl == $u)][0].labels.job' 2>/dev/null || true)
      target=$(python3 -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.argv[1]).query).get("target", [""])[0])' "$url")
      if ! grep -q '/login' <<<"$target"; then
        echo "not yet: the probe's target is $target. The page customers cannot use is /login;"
        echo "a probe of anything else can pass while sign-in is broken."
        exit 1
      fi
      # Why a probe fails, in blackbox_exporter's own words.
      why() {
        curl -s --max-time 15 "${url}&debug=true" | grep -E 'level=(error|ERROR)|msg=.*(fail|match)' |
          sed -E 's/.*msg=//' | awk '!seen[$0]++' | head -n 3 | cut -c1-200 | sed 's/^/  /' || true
      }
      ok_now() { prom_val "probe_success{job=\"$job\"}"; }

      firing() { prom_count 'ALERTS{alertstate="firing"}'; }
      # pending_on METRIC — pending alerts whose rule reads that metric.
      pending_on() {
        curl -s --max-time 10 "$PROM/api/v1/rules?type=alert" | jq -r --arg m "$1" '[.data.groups[].rules[]
          | select(.state == "pending" and (.query | contains($m))) | .name] | unique | join(", ")' 2>/dev/null || true
      }
      paged() {
        sink_all | jq -r '[.[] | select(.payload.status == "firing") | .payload.alerts[]
          | select(.status == "firing") | .labels.alertname] | unique | join(" ")' 2>/dev/null || true
      }
      settle() {
        for _ in $(seq 1 120); do [ "$(firing)" = 0 ] && break; sleep 1; done
        sleep 5
        sink_reset
      }
      # wait_page SECONDS — the alert names paged once something has paged
      # and a few more seconds have passed for any second alert to land.
      wait_page() {
        local p=
        for _ in $(seq 1 "$1"); do p=$(paged); [ -n "$p" ] && break; sleep 1; done
        [ -n "$p" ] && sleep 20 && p=$(paged)
        echo "$p"
      }

      # Round 1: everything is fine, and nothing may page.
      for _ in $(seq 1 30); do [ "$(ok_now)" = 1 ] && break; sleep 1; done
      if [ "$(ok_now)" != 1 ]; then
        echo "not yet: with portal healthy, the probe ($target) fails. blackbox_exporter says:"
        why
        echo "portal's certificate is self-signed: either trust it (tls_config.ca_file:"
        echo "/obs/portal/tls.crt) or skip verification; the expiry is reported either way."
        exit 1
      fi
      settle
      sleep 30
      # An alert that never stops firing paged before the sink was reset, and
      # Alertmanager does not repeat it within the hour.
      p=$(paged)
      [ -n "$p" ] || p=$(prom_query 'ALERTS{alertstate="firing"}' |
        jq -r '[.data.result[].metric.alertname] | unique | join(" ")' 2>/dev/null || true)
      if [ -n "$p" ]; then
        echo "not yet: with portal healthy and a certificate valid for a year, this paged: $p."
        echo "An expiry alert should fire inside a window that ends at the expiry date, a few weeks"
        echo "out, not on every certificate."
        exit 1
      fi
      echo "healthy: nothing paged"

      # Round 2: the login page breaks behind a 200.
      settle
      echo "the login page breaks; portal still answers 200..."
      touch /obs/run/portal.fault
      p=$(wait_page 90)
      probe=$(ok_now)
      pending=$(pending_on probe_success)
      rm -f /obs/run/portal.fault
      if [ -z "$p" ]; then
        if [ "$probe" = 1 ]; then
          echo "not yet: portal served its error page with status 200 for 90 seconds, and the probe"
          echo "still passed. A status check cannot tell the error page from the form; the module"
          echo "has to assert on what the page says (fail_if_body_not_matches_regexp)."
        elif [ -n "$pending" ]; then
          echo "not yet: the probe failed (probe_success 0) for 90 seconds, and $pending was still"
          echo "pending. A login page that has been broken for a minute is already news; shorten its for:."
        else
          echo "not yet: the probe failed (probe_success 0) for 90 seconds, and nothing paged."
          echo "Add an alert on the probe's result."
        fi
        exit 1
      fi
      if [ "$(wc -w <<<"$p")" != 1 ]; then
        echo "not yet: one broken login page sent $(wc -w <<<"$p") different alerts: $p. One break, one page."
        exit 1
      fi
      echo "  paged: $p"

      # Round 3: the certificate is about to expire.
      settle
      echo "portal is now served with a certificate that expires in 7 days..."
      short_cert=1
      cert 7
      p=$(wait_page 90)
      probe=$(ok_now)
      pending=$(pending_on probe_ssl_earliest_cert_expiry)
      cert 365; short_cert=
      if [ -z "$p" ]; then
        if [ "$(prom_count "probe_ssl_earliest_cert_expiry{job=\"$job\"}")" = 0 ]; then
          echo "not yet: the certificate expires in 7 days and nothing paged. The probe reports no"
          echo "probe_ssl_earliest_cert_expiry: is it probing https://?"
        elif [ -n "$pending" ]; then
          echo "not yet: the certificate expires in 7 days, nothing paged, and $pending was still pending."
          echo "Expiry is days away, not seconds; a for: longer than a minute or so only delays the page."
        else
          echo "not yet: the certificate expires in 7 days and nothing paged. probe_ssl_earliest_cert_expiry"
          echo "is the expiry as a Unix time; alert when it is less than some days from time()."
        fi
        exit 1
      fi
      if [ "$(wc -w <<<"$p")" != 1 ]; then
        echo "not yet: one expiring certificate sent $(wc -w <<<"$p") different alerts: $p."
        if [ "$probe" = 0 ]; then
          echo "The probe itself failed too: a probe that verifies against the old certificate"
          echo "fails on any new one. Trust the CA, or skip verification and rely on the expiry alert."
        fi
        exit 1
      fi
      echo "  paged: $p"
      echo "PASS — the probe sees the error page and the expiring certificate, one page each."
