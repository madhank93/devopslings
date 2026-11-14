---
kind: lesson
title: "a maintainer handed over a package, and the new one shipped a payload"
description: |
  November 2018: event-stream, a package with two million weekly downloads,
  had a new maintainer, and its next release depended on flatmap-stream,
  which stole wallet keys. Projects that pinned their own dependencies still
  installed it. Replay it against a Python service whose dependencies are
  already pinned, and build the three controls — a hash lockfile, a mirror,
  and a review gate on what enters the mirror — that each stop it alone.
name: incident-eventstream-2018
slug: incident-eventstream-2018
createdAt: "2026-11-14"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      # /srv/pypi/public stands in for the public registry, /srv/pypi/internal
      # for the company's mirror of it.
      rm -rf /srv/pypi
      mkdir -p /srv/pypi/internal/simple /srv/pypi/public/simple
      p=/srv/pypi/public/simple
      mkwheel "$p" ps-tree 1.1.0 --requires 'event-stream>=3.3,<4' --origin "ps-tree maintainer" >/dev/null
      mkwheel "$p" event-stream 3.3.4 --origin "original maintainer" >/dev/null
      mkwheel "$p" event-stream 3.3.5 --origin "original maintainer" >/dev/null
      mkwheel "$p" event-stream 3.3.6 --requires 'flatmap-stream>=0.1' --origin "new maintainer" >/dev/null
      mkwheel "$p" flatmap-stream 0.1.1 --origin "MALICIOUS: reads wallet keys" >/dev/null

      serve() {
        curl -s -o /dev/null "http://127.0.0.1:$1/simple/" && return 0
        setsid nohup python3 -m http.server "$1" --bind 127.0.0.1 --directory "$2" \
          >/dev/null 2>&1 </dev/null &
        for _ in $(seq 50); do
          curl -s -o /dev/null "http://127.0.0.1:$1/simple/" && return 0
          sleep 0.2
        done
        echo "index on port $1 did not start" >&2
        return 1
      }
      serve 3141 /srv/pypi/internal
      serve 8081 /srv/pypi/public

      rm -rf /work/wallet
      mkdir -p /work/wallet/ci
      cd /work/wallet
      echo 'ps-tree==1.1.0' > requirements.txt

      cat > ci/sync-mirror.sh <<'SH'
      #!/bin/sh
      # Nightly: bring the internal mirror up to date with the public index.
      set -eu
      pub=/srv/pypi/public/simple
      mirror=/srv/pypi/internal/simple
      for f in "$pub"/*/*.whl; do
        [ -e "$f" ] || continue
        project=$(basename "$(dirname "$f")")
        mkdir -p "$mirror/$project"
        cp -n "$f" "$mirror/$project/"
      done
      SH
      cat > ci/install.sh <<'SH'
      #!/bin/sh
      # CI's dependency step: a fresh virtualenv, installed from the mirror only.
      set -eu
      cd "$(dirname "$0")/.."
      rm -rf .venv
      python3 -m venv .venv
      .venv/bin/pip install --quiet --index-url http://127.0.0.1:3141/simple/ \
        --trusted-host 127.0.0.1 -r requirements.txt
      .venv/bin/pip list --format freeze
      SH
      chmod +x ci/sync-mirror.sh ci/install.sh

      cat > postmortem.txt <<'TXT'
      # requirements.txt pins ps-tree==1.1.0 exactly. Say, in a sentence or two,
      # why that pin did not keep flatmap-stream out.
      why_pinning_failed: ?
      TXT

      ci/sync-mirror.sh
      ci/install.sh > ci/last-run.log 2>&1 || true

      echo "scenario ready — the service is /work/wallet"
      echo
      echo "  last night's sync:     /work/wallet/ci/sync-mirror.sh"
      echo "  last night's install:  /work/wallet/ci/last-run.log"
      echo "  public index files:    /srv/pypi/public/simple/   (http://127.0.0.1:8081/simple/)"
      echo "  mirror files:          /srv/pypi/internal/simple/ (http://127.0.0.1:3141/simple/)"
      echo "  your write-up:         /work/wallet/postmortem.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      work=$(mktemp -d)
      approved=/work/wallet/ci/approved.txt
      saved=$work/approved.saved
      touched=""
      # Puts ci/approved.txt back exactly as the student left it, absent included.
      restore() {
        case $touched in
          had) cat "$saved" > "$approved" ;;
          absent) rm -f "$approved" ;;
        esac
        serve 8081 /srv/pypi/public >/dev/null 2>&1 || true
        rm -rf "$work"
      }
      serve() {
        curl -s -o /dev/null "http://127.0.0.1:$1/simple/" && return 0
        setsid nohup python3 -m http.server "$1" --bind 127.0.0.1 --directory "$2" \
          >/dev/null 2>&1 </dev/null &
        for _ in $(seq 50); do
          curl -s -o /dev/null "http://127.0.0.1:$1/simple/" && return 0
          sleep 0.2
        done
        return 1
      }
      trap restore EXIT

      # --- the write-up --------------------------------------------------------
      ans=$(sed -n 's/^why_pinning_failed:[[:space:]]*//p' /work/wallet/postmortem.txt 2>/dev/null | head -1 || true)
      if [ -z "$ans" ] || [ "$ans" = "?" ]; then
        echo "not yet: why_pinning_failed in /work/wallet/postmortem.txt is still empty."
        exit 1
      fi
      if [ "$(printf '%s' "$ans" | wc -w)" -lt 6 ]; then
        echo "not yet: why_pinning_failed is too short to explain anything. A sentence or two."
        exit 1
      fi
      if ! printf '%s' "$ans" | grep -Eiq '\b(transitive(ly)?|indirect(ly)?|sub-?dependenc(y|ies)|dependenc(y|ies) of (a |the |its |our )?dependenc(y|ies)|ps-tree (depends|required|requires|asks|pulls)|ranges?|>=)\b'; then
        echo "not yet: why_pinning_failed does not yet say what the pin did not cover. The pin"
        echo "is exact, and ps-tree 1.1.0 never changed. Look at which package did change, and"
        echo "who asked for it: pip show ps-tree, and its Requires line."
        exit 1
      fi

      for f in sync-mirror.sh install.sh; do
        if [ ! -f "/work/wallet/ci/$f" ]; then
          echo "not yet: /work/wallet/ci/$f is gone."
          exit 1
        fi
      done

      # --- the mirror, as the incident left it ------------------------------------
      # Everything the nightly sync copied in, plus a rebuilt event-stream 3.3.5
      # carrying the payload under the version you trust.
      rm -rf /srv/pypi
      mkdir -p /srv/pypi/internal/simple /srv/pypi/public/simple
      for idx in /srv/pypi/public/simple /srv/pypi/internal/simple; do
        mkwheel "$idx" ps-tree 1.1.0 --requires 'event-stream>=3.3,<4' --origin "ps-tree maintainer" >/dev/null
        mkwheel "$idx" event-stream 3.3.4 --origin "original maintainer" >/dev/null
        mkwheel "$idx" event-stream 3.3.5 --origin "original maintainer" >/dev/null
        mkwheel "$idx" event-stream 3.3.6 --requires 'flatmap-stream>=0.1' --origin "new maintainer" >/dev/null
        mkwheel "$idx" flatmap-stream 0.1.1 --origin "MALICIOUS: reads wallet keys" >/dev/null
      done
      mkwheel /srv/pypi/internal/simple event-stream 3.3.5 --build 1 --requires 'flatmap-stream>=0.1' --origin "new maintainer" >/dev/null
      if ! serve 3141 /srv/pypi/internal || ! serve 8081 /srv/pypi/public; then
        echo "not yet: the grader could not start the package indexes. Reset the scenario."
        exit 1
      fi

      # --- 1. the lockfile, with the public index unreachable --------------------
      # The bracket keeps this pattern from matching this script's own command line.
      pkill -f 'http[.]server 8081' 2>/dev/null || true
      sleep 0.5
      cp -a /work/wallet "$work/wallet"
      rm -rf "$work/wallet/.venv"
      rc=0
      (cd "$work/wallet" && env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root PIP_DISABLE_PIP_VERSION_CHECK=1 sh ci/install.sh) > "$work/out" 2>&1 || rc=$?
      serve 8081 /srv/pypi/public >/dev/null
      if [ ! -x "$work/wallet/.venv/bin/python" ]; then
        echo "not yet: run from another checkout, install.sh did not build .venv there."
        echo "Keep its paths relative to the repository — CI runs it in a fresh checkout."
        exit 1
      fi
      # A hash lockfile that refuses the rebuilt 3.3.5 fails the install closed:
      # red, with nothing installed. That is the lockfile doing its job.
      refused=""
      if [ "$rc" -ne 0 ] && grep -q 'DO NOT MATCH THE HASHES' "$work/out"; then
        refused=yes
      elif [ "$rc" -ne 0 ]; then
        echo "not yet: CI's install fails with the mirror holding everything the sync"
        echo "copied in and the public index unreachable. pip says:"
        grep -Ev '^\s*$' "$work/out" | tail -3 || true
        if grep -Eq '8081|Connection refused' "$work/out"; then
          echo "It is reaching for the public index; the install should need only the mirror."
        fi
        exit 1
      fi
      report=$("$work/wallet/.venv/bin/python" -c '
      import importlib, importlib.metadata as md
      for dist in ("ps-tree", "event-stream", "flatmap-stream"):
          try:
              v = md.version(dist)
              o = getattr(importlib.import_module(dist.replace("-", "_")), "ORIGIN", "?")
          except Exception:
              v, o = "missing", "-"
          print(dist, v, o.replace(" ", "_"))
      ' 2>/dev/null || true)
      flat=$(printf '%s\n' "$report" | awk '$1=="flatmap-stream"{print $2}')
      es=$(printf '%s\n' "$report" | awk '$1=="event-stream"{print $2, $3}')
      if [ "${flat:-missing}" != missing ]; then
        echo "not yet: with the incident's packages in the mirror, CI installed flatmap-stream"
        echo "$flat (event-stream ${es%% *}). The install has to be pinned all the way down."
        case $es in
          "3.3.5 new_maintainer")
            echo "It took event-stream 3.3.5 — a rebuild of the version you trust, published with"
            echo "a wheel build tag. Pin the files' hashes, not just their versions." ;;
        esac
        exit 1
      fi
      if [ -z "$refused" ] && [ "$es" != "3.3.5 original_maintainer" ] && [ "$es" != "3.3.4 original_maintainer" ]; then
        echo "not yet: CI installed event-stream ${es:-nothing}, not the original maintainer's"
        echo "3.3.5 the service was running before the incident."
        exit 1
      fi

      # --- 2. the review gate: a new malicious release is published --------------
      mkwheel /srv/pypi/public/simple event-stream 3.3.8 --requires 'flatmap-stream>=0.1.3' --origin "new maintainer" >/dev/null
      mkwheel /srv/pypi/public/simple flatmap-stream 0.1.3 --origin "MALICIOUS: reads wallet keys" >/dev/null
      if ! (cd /work/wallet && sh ci/sync-mirror.sh) > "$work/sync" 2>&1; then
        echo "not yet: ci/sync-mirror.sh fails:"
        tail -3 "$work/sync"
        exit 1
      fi
      leaked=$(ls /srv/pypi/internal/simple/event-stream/event_stream-3.3.8* \
                  /srv/pypi/internal/simple/flatmap-stream/flatmap_stream-0.1.3* 2>/dev/null || true)
      if [ -n "$leaked" ]; then
        echo "not yet: the grader published event-stream 3.3.8 and flatmap-stream 0.1.3, and the"
        echo "nightly sync copied them into the mirror without anyone approving them:"
        echo "$leaked" | sed 's|.*/|  |'
        exit 1
      fi

      # --- 3. the gate still lets reviewed packages through, and an unpublish --
      # --- upstream does not reach the mirror ----------------------------------
      if [ -f "$approved" ]; then cp "$approved" "$saved"; touched=had; else touched=absent; fi
      echo "left-pad==1.3.0" >> "$approved"
      mkwheel /srv/pypi/public/simple left-pad 1.3.0 --origin "left-pad maintainer" >/dev/null
      mv /srv/pypi/public/simple/event-stream "$work/unpublished"
      if ! (cd /work/wallet && sh ci/sync-mirror.sh) > "$work/sync" 2>&1; then
        echo "not yet: ci/sync-mirror.sh fails once event-stream is unpublished upstream:"
        tail -3 "$work/sync"
        exit 1
      fi
      if ! ls /srv/pypi/internal/simple/left-pad/left_pad-1.3.0-* >/dev/null 2>&1; then
        echo "not yet: the grader added left-pad==1.3.0 to ci/approved.txt, published it, and"
        echo "ran the sync; it did not reach the mirror. A gate nothing passes is a mirror"
        echo "that goes stale, and people start installing around it."
        exit 1
      fi
      if ! ls /srv/pypi/internal/simple/event-stream/event_stream-3.3.5-py3-none-any.whl >/dev/null 2>&1; then
        echo "not yet: event-stream was unpublished from the public index, and after the sync"
        echo "the mirror no longer has 3.3.5 either. When left-pad was unpublished in 2016,"
        echo "the builds that survived were the ones with their own copy."
        exit 1
      fi

      if [ -n "$refused" ]; then
        echo "(With the rebuilt event-stream 3.3.5 in the mirror, your lockfile failed the"
        echo "install on a hash mismatch and installed nothing — red, not compromised.)"
      fi
      echo "PASS — the lockfile kept the payload out with the mirror compromised, the gate"
      echo "kept a new malicious release out of the mirror while passing a reviewed one, and"
      echo "the mirror kept its copy when upstream disappeared."
---

## Why this exists

The event-stream compromise is the textbook case of an attack that the
obvious control does not stop. The original maintainer, no longer using the
package, handed it to a volunteer who had made a few helpful commits. The
volunteer added a new dependency, flatmap-stream, and a later release of that
contained an encrypted payload that only activated inside the build of one
Bitcoin wallet, Copay. It ran for about two months before anyone noticed.
Most affected projects had never heard of event-stream: it came in through
other packages' version ranges.

## What this replay simplifies

npm becomes pip, and the payload is a marker string. The packages are
fictional builds with the real names. The mirror is a directory served over
HTTP, and the review gate is a file of approved versions — in practice it is
an artifact manager's curation rules, a quarantine period for new releases,
or a reviewed pull request that bumps the lockfile.
