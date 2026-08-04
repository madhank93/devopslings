#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two independent problems wearing one error message.
set -euo pipefail

# 1. The ceiling. A drop-in rather than editing the shipped unit. `ulimit -n` in
#    an interactive shell changes that shell and its children — systemd started
#    this service, so the shell was never in its ancestry.
install -d /etc/systemd/system/feed-gateway.service.d
cat > /etc/systemd/system/feed-gateway.service.d/nofile.conf <<'CONF'
[Service]
LimitNOFILE=4096
CONF

# 2. The leak. `leaked.append(fh)` kept every per-request handle alive for the
#    lifetime of the process, on purpose. A with-block scopes it to the request.
#    Raising the limit alone only changes how long it takes to fall over.
cat > /usr/local/bin/feed-gateway <<'PY'
#!/usr/bin/env python3
import os, time, glob

IN = "/srv/feed/in"
OUT = "/srv/feed/processed.log"

shards = [open(p, "a") for p in sorted(glob.glob("/srv/feed/shards/*.log"))]
print(f"feed-gateway: ready, {len(shards)} shards open", flush=True)

processed = 0
while True:
    for path in sorted(glob.glob(os.path.join(IN, "*.job"))):
        try:
            with open(path) as fh:
                payload = fh.read().strip()

            shards[processed % len(shards)].write(payload + "\n")
            shards[processed % len(shards)].flush()
            with open(OUT, "a") as out:
                out.write(payload + "\n")
            processed += 1
            os.unlink(path)
        except OSError as e:
            print(f"feed-gateway: {e}", flush=True)
            time.sleep(0.2)
    time.sleep(0.05)
PY
chmod 0755 /usr/local/bin/feed-gateway

systemctl daemon-reload
# The unit has been crash-looping, so clear any failed state before starting.
systemctl reset-failed feed-gateway.service >/dev/null 2>&1 || true
systemctl restart feed-gateway.service
sleep 3
