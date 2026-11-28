#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# 4317 is OTLP over gRPC and 4318 is OTLP over HTTP. billing spoke HTTP to the
# gRPC port. Keeping the port and switching the exporter to gRPC makes them
# agree; http/protobuf with port 4318 would too.
set -euo pipefail
sed -i 's|^os.environ\["OTEL_EXPORTER_OTLP_PROTOCOL"\] = "http/protobuf"$|os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"|' \
  /obs/apps/billing.py
grep -q 'OTEL_EXPORTER_OTLP_PROTOCOL"\] = "grpc"' /obs/apps/billing.py
sed -i -e 's/^4317: ?.*/4317: grpc/' -e 's/^4318: ?.*/4318: http/' /obs/answers/otlp-ports.txt
