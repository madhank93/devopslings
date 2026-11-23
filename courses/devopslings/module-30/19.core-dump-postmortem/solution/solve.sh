#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The core is taken with gdb rather than through core_pattern, because the
# host's pattern may pipe cores to a handler outside this container. bt shows
# #0 in libc's strlen and #1 region_rate at the strlen(region) line: Q-1043
# has no region= line, so parse() leaves region NULL. Reject such requests.
set -euo pipefail
install -d /root/answers
systemctl stop tariffd.service
cd /var/lib/tariffd
gdb -q -batch -ex run -ex 'generate-core-file /var/tmp/tariffd.core' -ex kill /usr/local/bin/tariffd >/dev/null 2>&1 || true
test -s /var/tmp/tariffd.core
cat > /root/answers/core.txt <<A
core=/var/tmp/tariffd.core
function=region_rate
line=$(grep -n 'size_t n = strlen(region);' /usr/local/src/tariffd/tariffd.c | cut -d: -f1)
A
python3 - <<'PY'
p = "/usr/local/src/tariffd/tariffd.c"
s = open(p).read()
old = "    if (parse(in, &r) != 0)\n        return;\n"
assert old in s
s = s.replace(old, old + """    if (!r.region) {
        FILE *e = fopen(out, "w");
        if (e) {
            fprintf(e, "id=%s\\nerror=missing region\\n", r.id);
            fclose(e);
        }
        unlink(in);
        return;
    }
""")
open(p, "w").write(s)
PY
make -s -C /usr/local/src/tariffd install
systemctl restart tariffd.service
