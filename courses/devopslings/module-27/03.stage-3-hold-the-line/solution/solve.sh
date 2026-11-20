#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two changes, both needed:
#   drain    on SIGTERM the server fails /health, keeps serving until both
#            balancers have taken it out (two failed checks a second apart),
#            then closes; tofu stops a container with SIGTERM and a grace
#            period instead of removing it outright.
#   rolling  the deploy job replaces one replica at a time, and starts the
#            next only when both balancers have the last one back UP.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

version=$(sed -n 's/^const VERSION = "\([^"]*\)".*/\1/p' src/server.js | head -1)
cat > src/server.js <<JS
const http = require("node:http");
const os = require("node:os");

const VERSION = "${version}";

let draining = false;

const server = http.createServer((req, res) => {
  res.setHeader("content-type", "application/json");
  if (req.url === "/health") {
    res.statusCode = draining ? 503 : 200;
    res.end(JSON.stringify({ ok: !draining }));
    return;
  }
  res.end(JSON.stringify({ version: VERSION, node: os.hostname() }));
});
server.listen(8080);

// Leave rotation before leaving: fail the health check, keep serving while
// the balancers notice (two failed checks, a second apart), then close.
process.on("SIGTERM", () => {
  draining = true;
  setTimeout(() => {
    server.close(() => process.exit(0));
    server.closeIdleConnections();
    setTimeout(() => process.exit(0), 2000).unref();
  }, 4000);
});
JS

# docker stop with a grace period, instead of a forced remove.
perl -0pi -e 's/(  image = docker_image\.shop\.image_id\n)/$1  destroy_grace_seconds = 10\n/' deploy/main.tf
grep -q 'destroy_grace_seconds' deploy/main.tf

python3 - <<'PY'
p = ".forgejo/workflows/ci.yml"
s = open(p).read()
old = """          tofu plan -input=false -out=tfplan -var "image=${IMAGE}@${digest}"
          tofu apply -input=false tfplan
"""
new = """          # One replica at a time; the next only when both balancers have
          # the last one back.
          for i in 0 1; do
            tofu apply -input=false -auto-approve -target="docker_container.shop[$i]" \\
              -var "image=${IMAGE}@${digest}"
            for _ in $(seq 60); do
              up=$(docker exec devopslings-ha-ops sh -c \\
                     "curl -fsS 'http://lb1:8404/stats;csv'; curl -fsS 'http://lb2:8404/stats;csv'" \\
                   | awk -F, -v s="shop$((i + 1))" '$1 == "app" && $2 == s && $18 == "UP"' | wc -l || true)
              [ "$up" -eq 2 ] && break
              sleep 1
            done
          done
          tofu apply -input=false -auto-approve -var "image=${IMAGE}@${digest}"
"""
assert old in s, "deploy step not in the expected shape"
open(p, "w").write(s.replace(old, new))
PY

git add -A
git commit -qm "deploy: roll one replica at a time, and drain each on SIGTERM"
git push -q origin HEAD:main
