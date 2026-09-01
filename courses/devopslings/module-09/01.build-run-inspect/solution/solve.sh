#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The report lands in the container's own writable layer, which outlives the
# process: it can be copied out of the exited container. A bind mount puts the
# next run's report straight onto the host instead.
set -euo pipefail

cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY orders.csv report.py ./
CMD ["python3", "report.py"]
DOCKER

docker build -t devopslings-report .

docker rm -f report-run >/dev/null 2>&1 || true
docker run --name report-run devopslings-report

mkdir -p recovered out
docker cp report-run:/out/report.txt recovered/report.txt

docker run --rm -v "$(pwd)/out:/out" devopslings-report
