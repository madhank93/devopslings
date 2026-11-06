---
kind: lesson
title: "the backup alert that could not fire"
description: |
  Backups stopped for three days and nobody was paged. The alert compared the
  time of the last backup with now, and the job that reported that time had
  died, so there was nothing to compare. Make missing data page, without
  paging on every deploy.
name: absent-and-staleness
slug: absent-and-staleness
createdAt: "2026-10-15"
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
      cat > /obs/prometheus/rules/backup.yml <<'YML'
      groups:
        - name: backup
          rules:
            - alert: BackupStale
              expr: time() - backup_last_success_timestamp_seconds{job="backup"} > 30
              for: 10s
              labels:
                severity: critical
              annotations:
                summary: no backup has completed in 30 seconds
      YML
      chmod a+r /obs/prometheus/rules/backup.yml
      obs-reload >/dev/null
      echo "scenario ready: the backup alert is in /obs/prometheus/rules/backup.yml."
      echo "Every alert pages (/obs/alertmanager/alertmanager.yml); pages land in the sink:"
      echo "  curl -s sink:8080/notifications | jq '.[] | {path, status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'"

  verify_done:
    timeout_seconds: 720
    run: |
      . /usr/local/lib/obs.sh
      cleanup() { app_up backup; rm -f /obs/run/backup.fault; }
      trap cleanup EXIT
      cleanup
      obs_require_loaded || exit 1

      rules=$(curl -s --max-time 10 "$PROM/api/v1/rules?type=alert" || echo '{}')
      if [ "$(jq '[.data.groups[]?.rules[] | select(.name == "BackupStale")] | length' <<<"$rules" 2>/dev/null || echo 0)" = 0 ]; then
        echo "not yet: there is no BackupStale alert any more. It is the alert for backups that stop"
        echo "completing, which still happens; keep it, and add what it cannot see."
        exit 1
      fi

      # Alerts firing now, and the alert names that reached the pager since
      # the sink was last reset.
      firing() { prom_count 'ALERTS{alertstate="firing"}'; }
      paged() {
        sink_all | jq -r '[.[] | select(.path == "/pager" and .payload.status == "firing")
          | .payload.alerts[] | select(.status == "firing") | .labels.alertname] | unique | join(", ")' 2>/dev/null || true
      }
      settle() {
        for _ in $(seq 1 120); do [ "$(firing)" = 0 ] && break; sleep 1; done
        sleep 5
        sink_reset
      }
      state_of() {
        prom_query 'ALERTS' | jq -r '[.data.result[].metric | "\(.alertname) (\(.alertstate))"] | join(", ")' 2>/dev/null || true
      }

      # Round 1: a deploy. backup's exporter is gone for 15 seconds.
      settle
      echo "a deploy: backup's exporter stops for 15 seconds..."
      app_down backup
      sleep 15
      app_up backup
      sleep 45
      p=$(paged)
      if [ -n "$p" ]; then
        echo "not yet: a 15-second deploy paged: $p."
        echo "Every deploy, restart and scrape that times out makes the data disappear for a few"
        echo "seconds. An alert that pages on the first missing sample pages on all of them, and"
        echo "people learn to ignore it. It should wait out a gap longer than a deploy: for:, or a"
        echo "window as in absent_over_time(...[1m])."
        exit 1
      fi

      # Round 2: backup's exporter dies and stays dead.
      settle
      echo "backup's exporter stops and stays stopped..."
      app_down backup
      p=
      for _ in $(seq 1 120); do
        p=$(paged)
        [ -n "$p" ] && break
        sleep 1
      done
      state=$(state_of)
      app_up backup
      if [ -z "$p" ]; then
        echo "not yet: backup's exporter was gone for two minutes, and nothing paged."
        echo "Alerts in Prometheus at the end: ${state:-none}."
        if grep -q pending <<<"$state"; then
          echo "Something noticed and was still pending. A for: that long means backups can be"
          echo "unmonitored for that long before anyone hears; a minute or two is enough to ride out"
          echo "a deploy."
        elif jq -e '[.data.groups[]?.rules[] | .query] | any(test("absent(_over_time)?\\s*\\(\\s*up\\b"))' <<<"$rules" >/dev/null 2>&1; then
          echo "absent(up{...}) is only true when there is no up series at all. A target that is down"
          echo "still has one, with the value 0, so absent(up) stays empty. Watch the metric that"
          echo "disappeared, or up == 0."
        else
          echo "BackupStale computes time() minus a timestamp that no longer exists. With no series"
          echo "there is nothing to subtract from, the result is empty, and an empty result is never"
          echo "above 30. A threshold cannot fire on data that is not there; absent() can."
        fi
        exit 1
      fi
      echo "  paged: $p"

      # Round 3: backups stop completing, the exporter keeps reporting.
      settle
      echo "backups stop completing; the exporter keeps reporting the last one..."
      date +%s > /obs/run/backup.fault
      p=
      for _ in $(seq 1 90); do
        p=$(paged)
        [ -n "$p" ] && break
        sleep 1
      done
      rm -f /obs/run/backup.fault
      if [ -z "$p" ]; then
        echo "not yet: no backup completed for 90 seconds, the exporter reported it, and nothing paged."
        state=$(state_of)
        echo "Alerts in Prometheus: ${state:-none}."
        echo "The threshold alert has to keep firing on a backup that is late."
        exit 1
      fi
      echo "  paged: $p"

      echo "PASS — a dead exporter pages, a stale backup pages, and a deploy does not."
---
