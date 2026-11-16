#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The exporter's sending queue held 5 batches; a settlement run arrives as
# one request the batch processor splits into many, and the rest were
# rejected at enqueue, counted only in the Collector's own metrics. Size the
# queue in records with room for a month-end run, keep retries on, and alert
# on either drop counter going up.
set -euo pipefail
. /usr/local/lib/obs.sh
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["exporters"]["otlphttp/loki"]["sending_queue"] = {
    "num_consumers": 4, "sizer": "items", "queue_size": 20000}
c["exporters"]["otlphttp/loki"]["retry_on_failure"] = {"enabled": True, "max_elapsed_time": "10m"}
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
cat > /obs/prometheus/rules/pipeline.yml <<'YML'
groups:
  - name: log-pipeline
    rules:
      - alert: LogRecordsDropped
        expr: |
          sum by (exporter) (increase(otelcol_exporter_enqueue_failed_log_records_total[5m]))
            > 0
          or
          sum by (exporter) (increase(otelcol_exporter_send_failed_log_records_total[5m]))
            > 0
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.exporter }} is dropping log records"
YML
obs_reload >/dev/null
cat > /obs/answers/the-four-percent.txt <<'TXT'
where: the otlphttp/loki exporter's sending queue (otelcol_exporter_enqueue_failed_log_records_total)
TXT
