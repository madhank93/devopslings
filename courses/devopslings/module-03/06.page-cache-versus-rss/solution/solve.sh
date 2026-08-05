#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

install -d /root/answers

# memory.current charges the cgroup for page cache as well as anonymous memory.
# The 180M of `file` is a copy of catalog.dat that the kernel is keeping because
# nothing else needs the RAM yet — it will be dropped the instant something
# does, with no involvement from the process. It is not the application's
# memory in any sense that matters.
echo file > /root/answers/reclaimable

# The real leak is `anon`, and it is small: one 256 KiB buffer retained per
# cycle, growing in proportion to work done, and never reclaimable because
# there is nothing on disk to reconstruct it from.
#
# The read stays. It is the service's job, and the page cache it produces was
# never the problem.
cat > /usr/local/bin/catalog-api <<'PY'
#!/usr/bin/env python3
import time

cycles = 0

while True:
    with open("/srv/catalog/catalog.dat", "rb") as f:
        while f.read(4 * 1024 * 1024):
            pass

    # The buffer was never used after the cycle that made it. Nothing retains it
    # now, so the allocator reuses the same memory every time round.
    scratch = bytearray(256 * 1024)
    del scratch

    cycles += 1
    with open("/srv/catalog/.cycles", "w") as c:
        c.write(str(cycles))
    time.sleep(0.5)
PY
chmod 0755 /usr/local/bin/catalog-api

systemctl restart catalog-api.service
sleep 3
