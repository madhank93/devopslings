#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Three layers could have been lying and two of them can be ruled out by
# inspection. The application buffer is exonerated by the code itself: it
# already calls flush(), which is the call that empties Python's buffer into the
# kernel. The device cache is exonerated by what the volume is — a
# device-mapper target over a file, with no drive and no volatile cache to
# acknowledge anything early. What is left is the page cache, which is not a bug
# but the design: write(2) returns as soon as the kernel has the data, and the
# kernel writes it out when it gets round to it.
echo page-cache > /root/answers/layer

# fsync is the call that says "and now actually put it on the disk", and it is
# the one the acknowledgement has to come after. flush() and fsync() read like
# a pair and are not one: the first hands the record to the kernel, the second
# waits for the kernel to hand it to the storage.
#
# The fsync goes inside the with-block, before the record is acknowledged.
# Acknowledging first and persisting afterwards is the same bug with a smaller
# window.
cat > /usr/local/bin/ledger-append <<'PY'
#!/usr/bin/env python3
# Appends one record to the vault ledger and reports it committed.
import os
import sys

record = " ".join(sys.argv[1:])

with open("/srv/vault/ledger.log", "a") as f:
    f.write(record + "\n")
    # Out of Python's buffer and into the kernel...
    f.flush()
    # ...and out of the kernel and onto the disk, which is the part the caller
    # is being promised.
    os.fsync(f.fileno())

print("committed")
PY
chmod 0755 /usr/local/bin/ledger-append
