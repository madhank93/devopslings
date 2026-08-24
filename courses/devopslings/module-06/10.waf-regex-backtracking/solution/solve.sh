#!/bin/sh
# The rule keeps its meaning and loses the two places where the engine had a
# choice it could not resolve: adjacent .* either side of the =, and a + over a
# character class the tail can also match.
set -e

python3 - <<'PY'
lines = []
with open("/etc/waf/rules.conf") as f:
    for line in f:
        if line.startswith("sqli-inline-assignment\t"):
            name, rule = line.rstrip("\n").split("\t", 1)
            rule = rule.replace(r"(?:.*=.*)", r"(?:=.*)")
            rule = rule.replace(r")+[)]*", r")++[)]*")
            line = name + "\t" + rule + "\n"
        lines.append(line)
with open("/etc/waf/rules.conf", "w") as f:
    f.writelines(lines)
PY

# Half a second is longer than any rule that is doing arithmetic and shorter
# than anything a user would wait for.
printf 'budget_ms = 500\n' > /etc/waf/waf.conf

# Restarting is not part of the fix — the filter re-reads both files — but it is
# how a match already in progress is abandoned.
systemctl restart waf.service
for _ in $(seq 1 40); do
  curl -s -m 2 http://127.0.0.1:8090/healthz 2>/dev/null | grep -q ok && break
  sleep 0.5
done

cat > /root/answers/waf.md <<'ANS'
failure_mode: catastrophic backtracking
budget_ms: 500
ANS
