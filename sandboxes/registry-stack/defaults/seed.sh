#!/bin/sh
# Write the registry's default configuration into its volume, once. A lesson
# that rewrites it later is undone by `down -v`, which drops the volume.
set -eu
[ -f /etc/registry/config.json ] && exit 0
cp /opt/registry-defaults/config.json /etc/registry/config.json
htpasswd -Bbc /etc/registry/htpasswd devops devopslings
