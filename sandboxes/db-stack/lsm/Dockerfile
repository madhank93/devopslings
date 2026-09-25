# The LSM engine for the write-stall lesson.
#
# rocksdb-tools ships db_bench, which is both the ingest and the store: it
# opens a real RocksDB with the options it is given, so the level-0 triggers
# and the compaction concurrency in the lesson are the engine's own knobs
# rather than a simulation of them.
FROM debian:stable-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      rocksdb-tools procps \
 && rm -rf /var/lib/apt/lists/*
