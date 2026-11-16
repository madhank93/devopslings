---
kind: lesson
title: "The pipeline records the deployment, and it only remembers the last one"
description: |
  Every deploy moves a tag called production, so the dashboard always knows
  what is running — and nothing knows what ran yesterday, or when. Make the
  pipeline leave one event per deployment, with its commit and its time, and
  none for a deploy that failed.
name: emit-the-events
slug: emit-the-events
createdAt: "2026-11-16"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      url="http://devops:devopslings@127.0.0.1:3000/${repo}.git"

      for rule in $(curl -fsS $auth "${api}/repos/${repo}/branch_protections" 2>/dev/null \
                      | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                      | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
        curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/${rule}" >/dev/null 2>&1 || true
      done

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git init -q -b main "$work/c"
      cd "$work/c"
      git config user.email devops@example.invalid
      git config user.name devops
      mkdir -p .forgejo/workflows

      cat > deploy.sh <<'SH'
      #!/bin/sh
      # Stands in for checkout's deploy: it ships only if the health check passes.
      set -e
      sh ./healthcheck.sh
      echo "deployed $(git rev-parse --short HEAD) to production"
      SH

      cat > healthcheck.sh <<'SH'
      #!/bin/sh
      echo "checkout is healthy"
      SH

      cat > README.md <<'MD'
      # checkout

      Every push to main deploys. `.forgejo/workflows/deploy.yml` is the pipeline.
      MD

      # The pipeline from module 12, with a step somebody added so the
      # dashboard could show what production is running.
      cat > .forgejo/workflows/deploy.yml <<'YAML'
      name: deploy

      on:
        push:
          branches: [main]

      jobs:
        deploy:
          runs-on: docker
          steps:
            - uses: actions/checkout@v4
            - run: sh deploy.sh
            - name: record the deployment
              if: always()
              run: |
                git tag -f production
                git push -f origin production
      YAML

      git add -A
      git commit -qm "checkout, deployed on every push to main"
      # Main, and no tags at all: other lessons leave deploy history behind.
      git push -q --force --prune "$url" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'

      echo "scenario ready — every push to main deploys, and moves the tag 'production'"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  http://localhost:3000/devops/checkout/actions"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      url="http://devops:devopslings@127.0.0.1:3000/${repo}.git"

      # Waits for a commit's run to settle and prints its state. Empty means no
      # run ever reported; a pending one gets the long budget.
      settled_status() {
        _i=0
        _seen=0
        _state=""
        while [ "$_i" -lt 100 ]; do
          _state=$(curl -fsS $auth "${api}/repos/${repo}/commits/$1/status" 2>/dev/null \
                     | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p' || true)
          case "$_state" in
            success|failure|error) printf '%s' "$_state"; return 0 ;;
            pending) _seen=1 ;;
          esac
          _i=$((_i + 1))
          if [ "$_seen" = 0 ] && [ "$_i" -ge 20 ]; then break; fi
          sleep 3
        done
        printf '%s' "$_state"
      }

      work=$(mktemp -d)
      if ! git clone -q "$url" "$work/c" 2>/dev/null; then
        echo "not yet: could not clone devops/checkout"
        exit 1
      fi
      cd "$work/c"
      git config user.email grader@example.invalid
      git config user.name grader
      head_sha=$(git rev-parse HEAD)
      probes=""
      restore() {
        cd /
        git -C "$work/c" push -q --force "$url" "${head_sha}:refs/heads/main" >/dev/null 2>&1 || true
        # The probes' own deploy events go too, so a second check starts clean.
        for ref in $(git ls-remote --tags "$url" 2>/dev/null | awk -v p="$probes" '
                       BEGIN { split(p, a, " "); for (i in a) s[a[i]] = 1 }
                       s[$1] { sub(/\^\{\}$/, "", $2); print $2 }' | sort -u); do
          git -C "$work/c" push -q "$url" ":$ref" >/dev/null 2>&1 || true
        done
        rm -rf "$work"
      }
      trap restore EXIT

      # probe <name> [fail]: push a commit, wait for its run, set sha and state.
      probe() {
        printf '%s\n' "$1 $(date +%s)-$$" > probe.txt
        if [ "${2:-}" = fail ]; then
          printf '#!/bin/sh\necho "checkout is not healthy" >&2\nexit 1\n' > healthcheck.sh
        else
          git checkout -q "$head_sha" -- healthcheck.sh
        fi
        git add -A
        git commit -qm "grader: $1"
        pushed=$(date +%s)
        if ! git push -q "$url" HEAD:main 2>/dev/null; then
          echo "not yet: could not push a test commit to main"
          exit 1
        fi
        sha=$(git rev-parse HEAD)
        probes="$probes $sha"
        state=$(settled_status "$sha")
      }

      # The deploy events that point at a commit: "<tag> <type>" per line,
      # where type is commit for a lightweight tag and tag for an annotated one.
      events_for() {
        git fetch -q --force "$url" '+refs/tags/*:refs/tags/*' 2>/dev/null || true
        git for-each-ref --format='%(refname:short) %(objecttype) %(objectname) %(*objectname)' refs/tags/deploy/production |
          awk -v s="$1" '($2 == "commit" && $3 == s) || ($2 == "tag" && $4 == s) { print $1, $2 }'
      }

      check_event() { # <sha> <pushed-epoch> <what>
        ev=$(events_for "$1")
        if [ -z "$ev" ]; then
          echo "not yet: the $3 deployed ($1) and no tag under deploy/production/ points at it."
          prod=$(git rev-parse -q --verify 'refs/tags/production^{commit}' 2>/dev/null || true)
          if [ "$prod" = "$1" ]; then
            echo "         The tag 'production' points at it — and it pointed at the last deploy before that,"
            echo "         and will point at the next one. One ref per environment says what is running now."
            echo "         Deployment frequency and lead time need one record per deployment, kept."
          else
            echo "         Record each deployment as its own tag, deploy/production/<something unique per run>."
          fi
          exit 1
        fi
        tag=$(printf '%s\n' "$ev" | head -1 | awk '{ print $1 }')
        if printf '%s\n' "$ev" | awk '$2 == "commit"' | grep . >/dev/null && ! printf '%s\n' "$ev" | awk '$2 == "tag"' | grep . >/dev/null; then
          echo "not yet: $tag points at the $3, and it is a lightweight tag: a name for a commit and nothing"
          echo "         else. The only date anywhere near it is the commit's, which is when the change was"
          echo "         written, not when it reached production. Lead time is the gap between those two."
          echo "         An annotated tag (git tag -a) carries its own date and author."
          exit 1
        fi
        tag=$(printf '%s\n' "$ev" | awk '$2 == "tag" { print $1; exit }')
        when=$(git for-each-ref --format='%(taggerdate:unix)' "refs/tags/$tag")
        now=$(date +%s)
        if [ -z "$when" ] || [ "$when" -lt $(($2 - 120)) ] || [ "$when" -gt $((now + 120)) ]; then
          echo "not yet: $tag is dated $(git for-each-ref --format='%(taggerdate:iso)' "refs/tags/$tag"), and the $3 was pushed"
          echo "         at $(date -u -r "$2" '+%F %T' 2>/dev/null || date -u -d "@$2" '+%F %T') UTC. A deploy event's time is the time the deploy ran."
          exit 1
        fi
      }

      probe "first deploy"
      first=$sha first_pushed=$pushed
      if [ "$state" != success ]; then
        echo "not yet: a plain commit pushed to main finished '${state:-with no run at all}', not success."
        echo "         The deploy should pass for a change that touches nothing. Read the run:"
        echo "         http://localhost:3000/${repo}/actions"
        exit 1
      fi
      check_event "$first" "$first_pushed" "first test commit"

      probe "second deploy"
      if [ "$state" != success ]; then
        echo "not yet: the second test commit's run finished '${state:-with no run at all}', not success."
        exit 1
      fi
      check_event "$sha" "$pushed" "second test commit"
      if [ -z "$(events_for "$first")" ]; then
        echo "not yet: the second deploy has an event, and the first one's is gone. A tag that is moved or"
        echo "         recreated on every run is one record, overwritten. Give each deployment its own name."
        exit 1
      fi

      probe "failed deploy" fail
      if [ "$state" = success ]; then
        echo "not yet: a commit whose health check exits 1 was reported as success. The deploy did not"
        echo "         happen, and the pipeline has to say so."
        exit 1
      fi
      ev=$(events_for "$sha")
      if [ -n "$ev" ]; then
        echo "not yet: the health check failed, nothing was deployed, and $(printf '%s\n' "$ev" | head -1 | awk '{ print $1 }')"
        echo "         records a deployment of it anyway. Look at what decides whether the recording step runs."
        echo "         A failed deploy counted as a deploy inflates frequency and hides itself from change"
        echo "         failure rate."
        exit 1
      fi

      echo "PASS — two deploys, two events, each annotated with its commit and its own time; the failed"
      echo "       deploy went red and left no event."
---
