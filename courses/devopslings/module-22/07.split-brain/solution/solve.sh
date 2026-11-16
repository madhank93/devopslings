#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The majority's history wins: etcd2 and etcd3 hold every write that had a
# quorum. etcd1's one-member cluster is discarded and etcd1 rejoins as a new,
# empty member. The single write made on it is then reapplied on purpose.
set -euo pipefail
E() { local ep=$1; shift; etcdctl --endpoints="http://$ep:2379" --command-timeout=5s "$@"; }
until_ok() { local _; for _ in $(seq 60); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; "$@"; }

payments=$(E etcd1 get flags/payments --print-value-only)

# Down first: while it runs, it tells the others they have been removed.
node kill etcd1
node start etcd2
node start etcd3
until_ok E etcd2 put recovery/started "$(date +%s)"
E etcd2 del recovery/started >/dev/null

id=$(E etcd2 member list | awk -F', ' '$3 == "etcd1" { print $1 }')
E etcd2 member remove "$id"
# Refused until every remaining member has been connected for a few seconds.
until_ok E etcd2 member add etcd1 --peer-urls=http://etcd1:2380

cat > /ha/etcd/etcd1.env <<'ENV'
# Rejoined after the 13:05 incident: an empty data directory, joining the
# existing cluster.
ETCD_INITIAL_CLUSTER_STATE=existing
ETCD_DATA_DIR=/var/lib/etcd/rejoined
ENV
node start etcd1
until_ok E etcd1 endpoint health

E etcd2 put flags/payments "$payments"
sleep 2
E etcd1 member list
