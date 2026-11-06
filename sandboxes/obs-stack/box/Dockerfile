# The workbench and the apps share this image: Python with prometheus_client
# for the services, and the Prometheus and Alertmanager CLIs for the student.
FROM prom/prometheus:v3.5.0 AS prom
FROM prom/alertmanager:v0.28.1 AS am

FROM python:3.12-slim-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq procps less vim-tiny nano \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir prometheus-client==0.21.1
COPY --from=prom /bin/promtool /usr/local/bin/promtool
COPY --from=am /bin/amtool /usr/local/bin/amtool
COPY tools/obs.sh /usr/local/lib/obs.sh
COPY tools/ /usr/local/bin/
COPY baseline/ /opt/obs-baseline/
ENV PYTHONUNBUFFERED=1
WORKDIR /obs
