#!/bin/bash
# Start this member. Settings come from ETCD_* environment variables, which
# etcd reads natively; /ha/etcd/<name>.env overrides the defaults below.
# Restart the container to apply a change.
set -eu
f=/ha/etcd/$ETCD_NAME.env
if [ -f "$f" ]; then
  set -a; . "$f"; set +a
fi
: "${ETCD_DATA_DIR:=/var/lib/etcd/data}"
# ha-reset leaves this marker when the cluster has to be rebuilt from scratch.
if [ -f "/ha/etcd-wipe/$ETCD_NAME" ]; then
  echo "$ETCD_NAME: wipe requested, discarding /var/lib/etcd"
  rm -rf /var/lib/etcd/* "/ha/etcd-wipe/$ETCD_NAME"
fi
: "${ETCD_LISTEN_CLIENT_URLS:=http://0.0.0.0:2379}"
: "${ETCD_ADVERTISE_CLIENT_URLS:=http://$ETCD_NAME:2379}"
: "${ETCD_LISTEN_PEER_URLS:=http://0.0.0.0:2380}"
: "${ETCD_INITIAL_ADVERTISE_PEER_URLS:=http://$ETCD_NAME:2380}"
: "${ETCD_INITIAL_CLUSTER:=etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380}"
: "${ETCD_INITIAL_CLUSTER_STATE:=new}"
: "${ETCD_INITIAL_CLUSTER_TOKEN:=devopslings-ha}"
export ETCD_DATA_DIR ETCD_LISTEN_CLIENT_URLS ETCD_ADVERTISE_CLIENT_URLS \
  ETCD_LISTEN_PEER_URLS ETCD_INITIAL_ADVERTISE_PEER_URLS ETCD_INITIAL_CLUSTER \
  ETCD_INITIAL_CLUSTER_STATE ETCD_INITIAL_CLUSTER_TOKEN
exec etcd
