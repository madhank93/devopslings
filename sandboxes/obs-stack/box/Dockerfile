# The workbench and the apps share this image: Python with prometheus_client
# and the OpenTelemetry SDK for the services; the Prometheus, Alertmanager,
# Loki and Vector CLIs for the student; and the OpenTelemetry Collector, which
# runs as one of the supervised apps so that saving its config restarts it.
FROM prom/prometheus:v3.5.0 AS prom
FROM prom/alertmanager:v0.28.1 AS am
FROM grafana/logcli:3.5.1 AS logcli
FROM timberio/vector:0.47.0-debian AS vector
FROM otel/opentelemetry-collector-contrib:0.128.0 AS otelcol

FROM python:3.12-slim-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq procps less vim-tiny nano \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir prometheus-client==0.21.1 \
      opentelemetry-sdk==1.38.0 opentelemetry-exporter-otlp-proto-http==1.38.0 pyyaml==6.0.2
# Module 29: zero-code instrumentation of a Flask app, the B3 propagator, and
# the gRPC exporter beside the HTTP one. Versions pinned to match the SDK.
RUN pip install --no-cache-dir flask==3.1.1 opentelemetry-distro==0.59b0 \
      opentelemetry-instrumentation-flask==0.59b0 opentelemetry-instrumentation-urllib==0.59b0 \
      opentelemetry-propagator-b3==1.38.0 opentelemetry-exporter-otlp-proto-grpc==1.38.0
COPY --from=prom /bin/promtool /usr/local/bin/promtool
COPY --from=am /bin/amtool /usr/local/bin/amtool
COPY --from=logcli /usr/bin/logcli /usr/local/bin/logcli
COPY --from=vector /usr/bin/vector /usr/local/bin/vector
COPY --from=otelcol /otelcol-contrib /usr/local/bin/otelcol-contrib
COPY tools/obs.sh /usr/local/lib/obs.sh
COPY tools/ /usr/local/bin/
COPY baseline/ /opt/obs-baseline/
ENV PYTHONUNBUFFERED=1 \
    LOKI_ADDR=http://loki:3100
WORKDIR /obs
