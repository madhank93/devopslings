#!/bin/sh
# 127.0.0.1:15000 is the registry's one name everywhere: the host publishes it,
# and the daemon behind the mounted socket pushes to it. Inside this box it is
# forwarded, so a signature or a pinned reference made here is valid there too.
set -eu
socat TCP-LISTEN:15000,bind=127.0.0.1,fork,reuseaddr TCP:registry:5000 &
exec "$@"
