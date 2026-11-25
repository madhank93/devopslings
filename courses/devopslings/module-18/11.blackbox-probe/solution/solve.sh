#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A module that asserts on the form being there, a probe scrape of /login
# through blackbox_exporter, and one alert per failure: the probe failing, and
# the certificate inside two weeks of expiry.
set -euo pipefail
cat > /obs/blackbox/blackbox.yml <<'YML'
modules:
  http_2xx:
    prober: http
    timeout: 4s
  login_page:
    prober: http
    timeout: 4s
    http:
      valid_status_codes: [200]
      fail_if_not_ssl: true
      fail_if_body_not_matches_regexp:
        - 'name="password"'
      tls_config:
        ca_file: /obs/portal/tls.crt
YML
if ! grep -q 'job_name: login-probe' /obs/prometheus/prometheus.yml; then
  cat >> /obs/prometheus/prometheus.yml <<'YML'

  - job_name: login-probe
    metrics_path: /probe
    params:
      module: [login_page]
    static_configs:
      - targets: ["https://portal:8443/login"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
YML
fi
cat > /obs/prometheus/rules/login-probe.yml <<'YML'
groups:
  - name: login-probe
    rules:
      - alert: LoginProbeFailing
        expr: probe_success{job="login-probe"} == 0
        for: 15s
        labels:
          severity: critical
        annotations:
          summary: the login page fails from outside portal
      - alert: LoginCertExpiring
        expr: probe_ssl_earliest_cert_expiry{job="login-probe"} - time() < 14 * 86400
        labels:
          severity: critical
        annotations:
          summary: portal's certificate expires within two weeks
YML
obs-reload
