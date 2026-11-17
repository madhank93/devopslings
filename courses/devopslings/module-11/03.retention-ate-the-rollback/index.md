---
kind: lesson
title: "the rollback target was deleted on schedule"
description: |
  v1.8.0 shipped a bug and the rollback to v1.7.0 failed: the registry no
  longer had it. Nothing was hacked and nobody deleted anything by hand — a
  retention policy, written to stop CI builds filling the disk, did exactly
  what it says. Rewrite it so it still cleans up and never eats a rollback.
name: retention-ate-the-rollback
slug: retention-ate-the-rollback
createdAt: "2026-10-08"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 400
    run: |
      reset-registry
      reg=127.0.0.1:15000
      repo=$reg/shop/api
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      # The registry-wide policy as it was written: keep the last eight images.
      # gcInterval is seconds rather than hours so a retention pass is
      # something you can watch.
      jq '.storage.gcInterval = "10s"
          | .storage.retention = {
              dryRun: false,
              delay: "24h",
              policies: [{
                repositories: ["**"],
                deleteUntagged: true,
                keepTags: [{ mostRecentlyPushedCount: 8 }]
              }]
            }' /opt/registry-defaults/config.json > /etc/registry/config.json
      docker restart devopslings-zot >/dev/null
      until curl -s -o /dev/null http://127.0.0.1:15000/v2/; do sleep 1; done

      # A fortnight of CI: every commit on main is pushed as git-<sha>, and a
      # release is a build that also gets a version tag.
      work=$(mktemp -d)
      n=0
      build() {
        n=$((n + 1))
        sha=$(printf 'api-%s-%s' "$n" "$(date +%s%N)" | sha1sum | cut -c1-7)
        printf '{"commit":"%s","release":"%s"}\n' "$sha" "${1:-none}" > "$work/build.json"
        tar -C "$work" -cf "$work/layer.tar" build.json
        crane append -f "$work/layer.tar" -t "$repo:git-$sha" >/dev/null 2>&1
        [ -z "${1:-}" ] || crane tag "$repo:git-$sha" "$1" >/dev/null 2>&1
      }
      build; build; build v1.6.0
      build; build; build; build v1.7.0
      build; build; build; build; build; build v1.8.0
      build; build; build
      rm -rf "$work"

      # Wait for retention to have run over everything just pushed.
      since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      i=0
      while [ "$i" -lt 90 ]; do
        passes=$(docker logs --since "$since" devopslings-zot 2>&1 \
                   | grep -c 'gc successfully completed for /var/lib/registry/shop/api' || true)
        [ "$passes" -ge 2 ] && break
        i=$((i + 1))
        sleep 2
      done
      rm -f /root/.docker/config.json

      echo "scenario ready"
      echo
      echo "  registry config:  /etc/registry/config.json   (zot reloads it on save)"
      echo "  registry log:     docker logs devopslings-zot"
      echo
      echo "Production is on v1.8.0. The rollback:"
      echo "  \$ crane manifest $repo:v1.7.0"
      echo "  MANIFEST_UNKNOWN: manifest unknown"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 400
    run: |
      reg=127.0.0.1:15000
      repo=$reg/shop/api
      export DOCKER_CONFIG=$(mktemp -d)
      work=$(mktemp -d)
      trap 'rm -rf "$DOCKER_CONFIG" "$work"' EXIT
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      if ! jq -e . /etc/registry/config.json >/dev/null 2>&1; then
        echo "not yet: /etc/registry/config.json is not valid JSON, so zot kept running"
        echo "the previous policy. 'jq . /etc/registry/config.json' shows where it breaks."
        exit 1
      fi
      if [ "$(jq -r '.storage.retention.dryRun // false' /etc/registry/config.json)" = true ]; then
        echo "not yet: retention is in dryRun, so it deletes nothing. That stops it eating"
        echo "releases by also stopping it cleaning up after CI — the disk it was written"
        echo "to protect fills up instead."
        exit 1
      fi

      # Replay a release cycle through the policy as it is now: three releases,
      # each preceded by a run of ordinary CI builds.
      n=0
      build() {
        n=$((n + 1))
        sha=$(printf 'grader-%s-%s' "$n" "$(date +%s%N)" | sha1sum | cut -c1-7)
        printf '{"commit":"%s","release":"%s"}\n' "$sha" "${1:-none}" > "$work/build.json"
        tar -C "$work" -cf "$work/layer.tar" build.json
        crane append -f "$work/layer.tar" -t "$repo:git-$sha" >/dev/null 2>&1
        [ -z "${1:-}" ] || crane tag "$repo:git-$sha" "$1" >/dev/null 2>&1
      }
      for r in 1 2 3; do
        build; build; build; build; build
        build "v2.$r.0"
      done
      build; build; build; build

      since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      i=0
      passes=0
      while [ "$i" -lt 120 ]; do
        passes=$(docker logs --since "$since" devopslings-zot 2>&1 \
                   | grep -c 'gc successfully completed for /var/lib/registry/shop/api' || true)
        [ "$passes" -ge 2 ] && break
        i=$((i + 1))
        sleep 2
      done
      if [ "$passes" -lt 2 ]; then
        echo "not yet: no retention pass ran over shop/api within four minutes. Check that"
        echo "storage.gc is still true and gcInterval is still short."
        exit 1
      fi

      # The rollback window: each of the last three releases must still pull.
      for v in v2.1.0 v2.2.0 v2.3.0; do
        if ! crane export "$repo:$v" - 2>/dev/null | tar -xO build.json 2>/dev/null | grep -q "\"release\":\"$v\""; then
          echo "not yet: the grader pushed three releases among 24 CI builds, and after"
          echo "a retention pass $v cannot be pulled. A rollback to it would fail the"
          echo "way the rollback to v1.7.0 did."
          echo "Ask the registry why: docker logs devopslings-zot 2>&1 | grep '\"tag\":\"$v\"'"
          exit 1
        fi
      done

      ci=$(crane ls "$repo" 2>/dev/null | grep -c '^git-' || true)
      if [ "$ci" -gt 10 ]; then
        echo "not yet: $ci git-* builds survived a retention pass. The releases are safe"
        echo "because nothing is being cleaned up, which is the problem the policy was"
        echo "written to solve. Keep at most the ten most recent CI builds."
        exit 1
      fi
      if [ "$ci" -lt 1 ]; then
        echo "not yet: retention deleted every git-* build, including the one just pushed."
        echo "A tag that no keepTags rule matches is deleted; the CI builds need a rule too."
        exit 1
      fi

      echo "PASS — after a retention pass, v2.1.0, v2.2.0 and v2.3.0 all pull, and"
      echo "$ci CI builds are left."
---
