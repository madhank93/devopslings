# MinIO, built from its last community release.
#
# The upstream project is archived and its images and binaries are no longer
# published, so the server is compiled from the pinned source tag instead.
FROM golang:1.24.8-bookworm AS build
ARG MINIO_RELEASE=RELEASE.2025-10-15T17-29-55Z
RUN git clone --quiet --depth 1 --branch ${MINIO_RELEASE} https://github.com/minio/minio /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -o /out/minio .

FROM debian:trixie-20261005-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/minio /usr/local/bin/minio
EXPOSE 9000
ENTRYPOINT ["minio"]
