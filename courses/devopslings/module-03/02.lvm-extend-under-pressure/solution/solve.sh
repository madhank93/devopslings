#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three layers, three steps, and they have to happen in this order. Each one is
# online: nothing is unmounted and the writer never stops.
set -euo pipefail

# The spare PV is the one that is not already in a volume group.
spare=$(pvs --noheadings -o pv_name,vg_name | awk '$2 == "" {print $1; exit}')

# 1. Volume group: make the new physical volume part of the pool.
vgextend -qq datavg "$spare"

# 2. Logical volume: hand that free space to this LV. -l +100%FREE takes all of
#    it; -L +220M would take a fixed amount.
lvextend -qq -l +100%FREE /dev/datavg/datalv >/dev/null

# 3. Filesystem: the LV is bigger, and ext4 still believes it is the size it was
#    formatted at. This is the step df reflects, and the one people miss —
#    because the first two succeed and change nothing visible.
#
#    resize2fs grows a mounted ext4 online. (Shrinking is offline, which is why
#    growing is the easy direction and sizing generously up front is cheap.)
resize2fs /dev/datavg/datalv >/dev/null 2>&1

# `lvextend -r` does steps 2 and 3 together and is what you would use in
# practice; they are separated here so the failure mode is visible.
