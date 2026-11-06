#!/bin/sh
# dind starts with an empty image store on every fresh stack. Load busybox from
# the copy baked into this image so no lesson ever pulls, and create the network
# floci attaches Lambda functions to.
set -e
until docker info >/dev/null 2>&1; do sleep 1; done
docker image inspect busybox:1.37.0 >/dev/null 2>&1 \
  || docker import --change 'CMD ["sh"]' /opt/seed/busybox.tar busybox:1.37.0 >/dev/null
docker network inspect lambda >/dev/null 2>&1 || docker network create lambda >/dev/null
exec sleep infinity
