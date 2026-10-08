#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The fault is drawn at random, so this is the ladder the lesson teaches,
# walked in order and stopped at the first rung that answers: what is staging
# running, did the run that deployed it fail anywhere, did the tests run, and
# what did they run against.
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
auth="-u devops:devopslings"
repo="devops/checkout"
remote="http://devops:devopslings@127.0.0.1:3000/${repo}.git"
reg="http://127.0.0.1:5000"
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
drill="$(cd ../.. && pwd)/scratch/pipeline-triage-drill"
wf=.forgejo/workflows/release.yml

tasks() { curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" | tr '{' '\n'; }
label_sha() {
  cfg=$(curl -fsS -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/staging" \
          | tr -d ' \n' | sed -n 's/.*"config":{[^}]*"digest":"\(sha256:[0-9a-f]*\)".*/\1/p')
  curl -fsS "${reg}/v2/checkout/blobs/${cfg}" | tr ',' '\n' | sed -n 's/.*"git.sha":"\([0-9a-f]*\)".*/\1/p'
}
logs() {
  run=$(tasks | grep "\"head_sha\":\"$1\"" | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1)
  for j in 0 1 2 3 4; do
    curl -fsS $auth "http://127.0.0.1:3000/${repo}/actions/runs/${run}/jobs/${j}/logs" || true
  done
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "$remote" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops
tip=$(git rev-parse HEAD)
running=$(label_sha)
# Held in variables and matched with case: grep -q closing a pipe early would
# fail the pipeline under pipefail and send the ladder down the wrong rung.
tip_jobs=$(tasks | grep "\"head_sha\":\"$tip\"" || true)
tip_logs=$(logs "$tip")

fix_qty() { sed -i.bak 's/item\.price \* (item\.quantity ?? 1)/item.price * item.qty/' src/cart.js; rm -f src/cart.js.bak; }

# ---- 1. is staging running the tip of main? -------------------------------
if [ "$running" != "$tip" ] && git merge-base --is-ancestor "$running" "$tip"; then
  # An older commit on main: the deploy promoted a tag nothing moves any more.
  sed -i.bak 's/\${IMAGE}:latest/${IMAGE}:${{ github.sha }}/g' "$wf"
  cause="deploy-staging promoted the :latest tag, which the 1.4 build stopped pushing, so staging kept 1.3's image"
  evidence="staging's git.sha label is the 1.3 commit and its digest is :latest's, not the tip's checkout:<sha>"
  detection="alert when staging's git.sha has not matched the tip of main for 15 minutes"
elif [ "$running" != "$tip" ]; then
  # A commit on no branch of main: something other than main wrote staging.
  awk '{print} /^    needs: \[build\]$/ {print "    if: github.ref == '\''refs/heads/main'\''"}' "$wf" > "$wf.new"
  mv "$wf.new" "$wf"
  for b in $(git branch -r | sed -n 's|^ *origin/\(hotfix/.*\)|\1|p'); do
    curl -fsS $auth -X DELETE "${api}/repos/${repo}/branches/$(printf '%s' "$b" | sed 's|/|%2F|g')" >/dev/null
  done
  cause="a hotfix branch deployed to staging after main did, so staging ran a commit that is not on main"
  evidence="the git.sha label on checkout:staging is on hotfix/discount-message; git branch -r --contains shows no main"
  detection="alert when staging's git.sha has not matched the tip of main for 15 minutes"
# ---- 2. did any job of the run that deployed it fail? ----------------------
elif case "$tip_jobs" in *'"status":"failure"'*) true ;; *) false ;; esac; then
  sed -i.bak 's/run: echo "all shards complete"/run: test "${{ needs.test.result }}" = success/' "$wf"
  fix_qty
  cause="the gate ran with if: always() and never read needs.test.result, so it passed with the cart shard red"
  evidence="the run for the tip: test (cart) failed, then gate, build and deploy-staging succeeded"
  detection="page on any deploy from a run with more than 0 failed jobs"
# ---- 3. did the tests run at all? -----------------------------------------
elif case "$tip_logs" in *"# tests"*) false ;; *) true ;; esac; then
  sed -i.bak 's/"tests": "node --test"/"test": "node --test"/' package.json
  rm -f package.json.bak
  fix_qty
  cause="package.json names the script tests and the workflow runs npm run test --if-present, so no tests ran"
  evidence="the test job logs have no # tests summary, and package.json has no test script"
  detection="fail the run when fewer than 5 tests ran"
# ---- 4. what did they run against? ----------------------------------------
else
  sed -i.bak "s/key: deps-\${{ runner.os }}\$/key: deps-\${{ runner.os }}-\${{ hashFiles('package-lock.json') }}/" "$wf"
  # Honest CI goes red on pricing-rules 2.0.0: it drops legacyRound and raises
  # the cap past the policy the tests hold. The upgrade goes back out.
  sed -i.bak 's/pricing-rules-2\.0\.0/pricing-rules-1.0.0/g; s/"version": "2\.0\.0"/"version": "1.0.0"/' package.json package-lock.json
  sed -i.bak 's|"integrity": "[^"]*"|"integrity": "sha512-hvPjo0jWmhkfImw8EYixYoZbWpcUg9nQosWwdpmUllSvRO5Cm5dorpuyvmz7K0mwkTVznGBseyJSsosksQK3Cw=="|' package-lock.json
  rm -f package.json.bak package-lock.json.bak
  cause="the cache key ignored package-lock.json, so CI restored 1.0.0 node_modules after the lockfile moved to pricing-rules 2.0.0"
  evidence="Cache restored from key: deps-Linux in the test log of the commit that changed the lockfile"
  detection="fail the run when the installed pricing-rules version differs from the lockfile, 0 tolerance"
fi
rm -f "$wf.bak"

git add -A
git commit -qm "repair the release pipeline"
git push -q origin HEAD:main

mkdir -p "$drill/answers"
printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" > "$drill/answers/triage.md"
