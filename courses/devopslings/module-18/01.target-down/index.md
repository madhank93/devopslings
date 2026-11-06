---
kind: lesson
title: "shop is running, and Prometheus has never heard of it"
description: |
  shop serves customers all day. Its dashboard is empty, and the Targets page
  has no shop on it at all, up or down. Restarting Prometheus changes nothing.
  Get shop scraped through service discovery, the way the deploy pipeline
  publishes it, without scraping the host that was retired.
name: target-down
slug: target-down
createdAt: "2026-10-15"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      mkdir -p /obs/prometheus/targets

      # The deploy pipeline's view of the world: shop on its service port, and
      # a host that was decommissioned but is still listed.
      cat > /obs/prometheus/targets/shop.json <<'JSON'
      [
        {"targets": ["shop:8080"], "labels": {"env": "prod", "team": "storefront"}},
        {"targets": ["legacy-shop:8080"], "labels": {"env": "retired", "team": "storefront"}}
      ]
      JSON

      cat > /obs/prometheus/prometheus.yml <<'YML'
      global:
        scrape_interval: 5s
        scrape_timeout: 4s
        evaluation_interval: 5s

      rule_files:
        - /obs/prometheus/rules/*.yml

      alerting:
        alertmanagers:
          - static_configs:
              - targets: ["alertmanager:9093"]

      scrape_configs:
        - job_name: prometheus
          static_configs:
            - targets: ["localhost:9090"]

        # shop's targets come from the deploy pipeline, which rewrites
        # targets/shop.json on every deploy.
        - job_name: shop
          file_sd_configs:
            - files: ["/obs/prometheus/targets/*.json"]
              refresh_interval: 5s
          relabel_configs:
            # Scrape only what is deployed to production.
            - source_labels: [env]
              regex: production
              action: keep

        - job_name: db
          static_configs:
            - targets: ["db:9101"]

        - job_name: loadgen
          static_configs:
            - targets: ["loadgen:9101"]
      YML
      chmod -R a+rX /obs/prometheus
      obs-reload >/dev/null
      echo "scenario ready: shop is serving traffic, and Prometheus scrapes nothing from it."
      echo "Look at http://localhost:19090/targets, then /obs/prometheus/prometheus.yml."

  verify_done:
    timeout_seconds: 120
    run: |
      . /usr/local/lib/obs.sh
      sd=/obs/prometheus/targets/shop.json

      # The pipeline deploys again before every check: shop now runs on two
      # hosts, and the file is rewritten whatever was in it.
      initial='[{"targets":["shop:8080"],"labels":{"env":"prod","team":"storefront"}},{"targets":["legacy-shop:8080"],"labels":{"env":"retired","team":"storefront"}}]'
      deployed='[{"targets":["shop:8080","shop-2:8080"],"labels":{"env":"prod","team":"storefront"}},{"targets":["legacy-shop:8080"],"labels":{"env":"retired","team":"storefront"}}]'
      norm() { jq -cS . 2>/dev/null || echo invalid; }
      now=$(norm < "$sd" 2>/dev/null || echo missing)
      edited=no
      if [ "$now" != "$(printf '%s' "$initial" | norm)" ] && [ "$now" != "$(printf '%s' "$deployed" | norm)" ]; then
        edited=yes
      fi
      printf '%s\n' "$deployed" | jq . > "$sd.tmp" && mv "$sd.tmp" "$sd"
      chmod a+r "$sd"

      obs_require_loaded || exit 1

      # Discovery, relabelling and the first scrape of a new target take a few
      # seconds; wait for them before judging.
      state() {
        curl -s --max-time 10 "$PROM/api/v1/targets?state=any" | jq -c '
          def host: (.scrapeUrl // "" | capture("//(?<h>[^:/]+)").h? // "");
          def dhost: (.discoveredLabels.__address__ // "" | split(":")[0]);
          {
            legacy: [.data.activeTargets[] | select(host == "legacy-shop" or dhost == "legacy-shop") | .scrapeUrl],
            shops:  [.data.activeTargets[] | select(.labels.job == "shop") | select(host == "shop" or host == "shop-2")
                     | {h: host, url: .scrapeUrl, health, err: .lastError}],
            other:  [.data.activeTargets[] | select(.labels.job != "shop") | select(host == "shop" or host == "shop-2") | .labels.job],
            dropped: [.data.droppedTargets[]? | select(dhost == "shop" or dhost == "shop-2") | .discoveredLabels]
          }' 2>/dev/null || echo '{"legacy":[],"shops":[],"other":[],"dropped":[]}'
      }
      for _ in $(seq 1 30); do
        s=$(state)
        ok=$(printf '%s' "$s" | jq '([.shops[] | select(.health == "up") | .h] | unique | length) == 2 and (.legacy | length) == 0')
        [ "$ok" = true ] && break
        sleep 1
      done

      note() {
        if [ "$edited" = yes ]; then
          echo "(You had edited targets/shop.json. The pipeline owns that file and has just"
          echo "rewritten it, so a fix made there does not survive a deploy.)"
        fi
      }

      if [ "$(printf '%s' "$s" | jq '.legacy | length')" -gt 0 ]; then
        echo "not yet: Prometheus is scraping legacy-shop, which was decommissioned — its entry in"
        echo "targets/shop.json carries env=retired. The pipeline still lists it, so the scrape"
        echo "config has to keep it out: the env filter should let prod through and nothing else."
        note; exit 1
      fi

      hosts=$(printf '%s' "$s" | jq -r '[.shops[].h] | unique | join(",")')
      if [ -z "$hosts" ]; then
        if [ "$(printf '%s' "$s" | jq '.dropped | length')" -gt 0 ]; then
          env=$(printf '%s' "$s" | jq -r '.dropped[0].env // "none"')
          echo "not yet: Prometheus discovers shop from targets/shop.json and then drops it before"
          echo "scraping. Status → Service discovery lists it under dropped targets. shop's env label"
          echo "is \"$env\"; read each relabel rule in the shop job and ask what it does to that."
        elif [ -n "$(printf '%s' "$s" | jq -r '.other | join(",")')" ]; then
          echo "not yet: shop is scraped, but under job=\"$(printf '%s' "$s" | jq -r '.other[0]')\". Dashboards and alerts"
          echo "select job=\"shop\"; keep the job name."
        else
          echo "not yet: Prometheus does not discover shop at all. The shop job should read its"
          echo "targets from /obs/prometheus/targets/*.json."
        fi
        note; exit 1
      fi

      if [ "$hosts" != "shop,shop-2" ]; then
        echo "not yet: the pipeline has just deployed shop to a second host, shop-2, and listed it in"
        echo "targets/shop.json. Prometheus scrapes only $hosts. A target written into"
        echo "prometheus.yml does not follow deploys; the shop job has to read the targets file."
        note; exit 1
      fi

      bad=$(printf '%s' "$s" | jq -r '[.shops[] | select(.health != "up")][0] // empty | "\(.url)\t\(.err)"')
      if [ -n "$bad" ]; then
        url=${bad%%$'\t'*}; err=${bad#*$'\t'}
        echo "not yet: Prometheus finds shop now and the scrape fails."
        echo "  $url → ${err:-no answer yet}"
        if grep -q '404' <<<"$err"; then
          echo "Something answers on that port, and it is not a metrics endpoint. The discovered"
          echo "address is shop's service port. Which port does shop.py serve metrics on? The"
          echo "pipeline only publishes the service port, so the scrape config has to translate it."
        fi
        note; exit 1
      fi

      if ! prom_wait 'shop_http_requests_total{job="shop",env="prod",team="storefront"}' 15; then
        got=$(prom_query 'count by (env, team) (shop_http_requests_total{job="shop"})' | jq -c '[.data.result[].metric]' 2>/dev/null || echo '[]')
        echo "not yet: shop is scraped, but its series do not carry env=\"prod\" and team=\"storefront\" from"
        echo "the targets file (they have: $got). Dashboards filter on those labels."
        note; exit 1
      fi

      echo "PASS — shop:8080 and shop-2:8080 are discovered, scraped on their metrics port and up,"
      echo "and legacy-shop stays out."
---
