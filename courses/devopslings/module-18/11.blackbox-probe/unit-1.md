---
title: "green dashboards, nobody can log in"
---

## The situation

Support is flooded: customers cannot sign in. On the dashboard, portal (the
login service) is fine:

```
promq 'sum by (code) (rate(portal_http_requests_total[1m]))'
promq 'ALERTS'
```

Every request it counts is a 200, and `PortalErrors` is quiet. Now look at
the page the way a customer does:

```
curl -sk https://portal:8443/login
```

The page behind the form is broken and portal serves its error page, with
status 200. portal's metrics are portal's opinion of itself, and portal
thinks it answered. No metric a service exports can see a request that went
wrong in a way the service does not know about, or one that never reached it:
a broken page, an expired certificate, a DNS record pointing somewhere else,
a load balancer that drops the connection.

## Probing from outside

**blackbox_exporter** makes the request a customer would make and reports
what happened. It runs here at `blackbox:9115`. Prometheus does not scrape
the page itself; it scrapes the exporter, and the exporter probes:

```
curl -s 'blackbox:9115/probe?module=http_2xx&target=https://portal:8443/login'
```

Try it. The answer is a small set of metrics about that one request:
`probe_success` (1 or 0), `probe_http_status_code`, `probe_duration_seconds`,
and for HTTPS `probe_ssl_earliest_cert_expiry`, the certificate's expiry as a
Unix time. Add `&debug=true` to see why a probe failed.

A **module** in `/obs/blackbox/blackbox.yml` says what a probe checks. The
`http` prober can require status codes, require HTTPS, and require that the
body matches (or does not match) a regular expression. `http_2xx` only
checks the status, which is why it passes against the error page.

portal's certificate is self-signed. A probe that verifies it fails with
"unknown authority" unless it trusts it: `tls_config.ca_file` points at the
certificate (`/obs/portal/tls.crt`), or `tls_config.insecure_skip_verify`
skips verification. The expiry is reported either way.

To have Prometheus probe on every scrape, the scrape job's address becomes a
URL parameter and the real address becomes the exporter's. The standard
relabelling does exactly that:

```yaml
  - job_name: login-probe
    metrics_path: /probe
    params:
      module: [YOUR_MODULE]
    static_configs:
      - targets: ["https://portal:8443/login"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

## Your objectives

1. A module that fails when `/login` does not serve the sign-in form, even
   with a 200.
2. A probe of `https://portal:8443/login` through that module, scraped by
   Prometheus.
3. An alert when the probe fails, and an alert when portal's certificate is
   inside two weeks of its expiry.
4. One page per problem: a broken page sends one alert, an expiring
   certificate sends one alert.

Edit `/obs/blackbox/blackbox.yml`, `/obs/prometheus/prometheus.yml` and a rule
file in `/obs/prometheus/rules/`, then `obs-reload`, which reloads
blackbox_exporter too. Every alert pages; pages land in the sink:

```
curl -s sink:8080/notifications | jq '.[] | {status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'
```

`/obs/run/portal.fault` is what breaks the page; delete it and the form comes
back. To try a short-lived certificate:

```
echo 7 > /obs/portal/cert-days; rm /obs/portal/tls.*; touch /obs/run/portal.restart
```

## What you're being graded on

- Prometheus scrapes a blackbox_exporter probe of portal's `/login`
- with portal healthy, the probe passes and nothing pages for 30 seconds
- portal serves the error page with a 200: exactly one alert pages within 90
  seconds
- portal is served with a certificate that expires in 7 days: exactly one
  alert pages within 90 seconds

The check breaks and repairs portal itself and takes a few minutes.

<details>
<summary>Hint 1</summary>

The form has an input named `password`; the error page does not. A module
with `fail_if_body_not_matches_regexp: ['name="password"']` fails on the
error page.

</details>

<details>
<summary>Hint 2</summary>

`probe_ssl_earliest_cert_expiry - time()` is the seconds left on the
certificate. Compare it with `14 * 86400`.

</details>

<details>
<summary>Solution</summary>

`/obs/blackbox/blackbox.yml`:

```yaml
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
```

The scrape job from above with `module: [login_page]`, and the rules:

```yaml
groups:
  - name: login-probe
    rules:
      - alert: LoginProbeFailing
        expr: probe_success{job="login-probe"} == 0
        for: 15s
        labels:
          severity: critical
      - alert: LoginCertExpiring
        expr: probe_ssl_earliest_cert_expiry{job="login-probe"} - time() < 14 * 86400
        labels:
          severity: critical
```

### The ways this goes wrong

- **`http_2xx`.** The error page is a 200, so the probe passes. A status
  check cannot see a page that is wrong but served.
- **A body check for the error text** (`fail_if_body_matches_regexp:
  ['went wrong']`). It catches this error page and not the next one with
  different words. Assert on what a working page must contain.
- **Verifying a self-signed certificate with no CA.** Every probe fails, and
  the alert fires all day.
- **An expiry threshold longer than the certificate's life** (`< 400 * 86400`).
  Fires on every certificate.
- **No `for:` on a probe alert.** One dropped probe pages. A few scrapes of
  patience is the difference between an outage and a blip.

</details>
