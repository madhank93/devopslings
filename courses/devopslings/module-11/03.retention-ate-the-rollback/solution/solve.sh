#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Two rules instead of one: releases are kept by version pattern, and CI builds
# by count. A tag is kept if any rule keeps it.
set -euo pipefail

cfg=/etc/registry/config.json
jq '.storage.retention.policies = [{
      repositories: ["**"],
      deleteUntagged: true,
      keepTags: [
        { patterns: ["^v[0-9]+\\.[0-9]+\\.[0-9]+$"], mostRecentlyPushedCount: 10 },
        { patterns: ["^git-"], mostRecentlyPushedCount: 8 }
      ]
    }]' "$cfg" > /tmp/config.json
cat /tmp/config.json > "$cfg"
