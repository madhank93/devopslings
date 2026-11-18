#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The checklist line becomes ci/policy.js, run on every push: production needs
# 2+ replicas unless a matching exception exists that has not expired and
# expires within 90 days. search gets its second replica; batch-reporter gets
# its exception.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/deployments.git" "$work/d"
cd "$work/d"
git config user.email devops@example.invalid
git config user.name devops

cat > ci/policy.js <<'JS'
// min-replicas: production services run at least 2 replicas, unless
// policy/exceptions.json holds a live exception for them. An exception is live
// from today until its expires date, and may not be dated more than 90 days out.
const fs = require("node:fs");

const MAX_DAYS = 90;
const today = new Date().toISOString().slice(0, 10);
const horizon = new Date(Date.now() + MAX_DAYS * 864e5).toISOString().slice(0, 10);

const exceptions = JSON.parse(fs.readFileSync("policy/exceptions.json", "utf8"));
const problems = [];

function liveException(service, rule) {
  const e = exceptions.find((x) => x.service === service && x.rule === rule);
  if (!e) return false;
  if (!e.reason) { problems.push(`${service}: exception for ${rule} has no reason`); return false; }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(e.expires || "")) { problems.push(`${service}: exception for ${rule} has no expires date`); return false; }
  if (e.expires < today) { problems.push(`${service}: exception for ${rule} expired on ${e.expires}`); return false; }
  if (e.expires > horizon) { problems.push(`${service}: exception for ${rule} expires ${e.expires}, more than ${MAX_DAYS} days out`); return false; }
  return true;
}

for (const f of fs.readdirSync("services").filter((f) => f.endsWith(".json"))) {
  const s = JSON.parse(fs.readFileSync(`services/${f}`, "utf8"));
  if (s.environment !== "production") continue;
  const replicas = Number.isInteger(s.replicas) ? s.replicas : 1; // the deployer's default
  if (replicas < 2 && !liveException(s.service, "min-replicas")) {
    problems.push(`${s.service}: production with ${replicas} replica(s) (min-replicas)`);
  }
}

if (problems.length) {
  for (const p of problems) console.error(`policy: ${p}`);
  process.exit(1);
}
console.log("policy: ok");
JS

cat >> .forgejo/workflows/validate.yml <<'YML'
      - run: node ci/policy.js
YML

sed -i.bak 's/"replicas": 1/"replicas": 2/' services/search.json && rm -f services/search.json.bak

expires=$(node -e 'console.log(new Date(Date.now()+60*864e5).toISOString().slice(0,10))' 2>/dev/null \
  || date -u -d '+60 days' +%F 2>/dev/null || date -u -v+60d +%F)
cat > policy/exceptions.json <<JSON
[
  {
    "service": "batch-reporter",
    "rule": "min-replicas",
    "reason": "holds the nightly export lock; a second replica runs the export twice",
    "expires": "${expires}"
  }
]
JSON

git add -A
git commit -qm "policy: min-replicas in CI, batch-reporter's exception, search at 2"
git push -q origin HEAD:main
