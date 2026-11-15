---
kind: lesson
title: "pip installed someone else's acme-billing"
description: |
  The billing service depends on `acme-billing`, a package that only exists
  on the company's internal index. Last night CI installed version 99.0.0 of
  it — from the public index, published by a stranger. Change how the service
  resolves its dependencies so an internal name can only ever come from the
  internal index, whatever the public one publishes next.
name: dependency-confusion
slug: dependency-confusion
createdAt: "2026-11-14"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      # The two package indexes: the company's (internal packages, plus a
      # mirror of the public ones it uses) and a stand-in for pypi.org.
      rm -rf /srv/pypi
      mkdir -p /srv/pypi/internal/simple /srv/pypi/public/simple
      i=/srv/pypi/internal/simple p=/srv/pypi/public/simple
      mkwheel "$i" acme-billing 1.4.0 --requires 'acme-ledger>=2,<3' --requires 'retrying-lite>=1.2' --origin internal >/dev/null
      mkwheel "$i" acme-ledger 2.1.0 --origin internal >/dev/null
      mkwheel "$i" retrying-lite 1.2.0 --origin pypi >/dev/null
      mkwheel "$p" retrying-lite 1.2.0 --origin pypi >/dev/null
      mkwheel "$p" acme-billing 99.0.0 --origin "impostor on the public index" >/dev/null

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

      rm -rf /work/billing
      mkdir -p /work/billing/ci
      cd /work/billing
      cat > requirements.txt <<'TXT'
      acme-billing
      retrying-lite>=1.2
      TXT
      cat > pip.conf <<'CONF'
      # http://127.0.0.1:8081 is the public index (pypi.org here).
      # http://127.0.0.1:3141 is ours: internal packages and a mirror of the
      # public ones we use.
      [global]
      index-url = http://127.0.0.1:8081/simple/
      extra-index-url = http://127.0.0.1:3141/simple/
      trusted-host = 127.0.0.1
      CONF
      cat > ci/install.sh <<'SH'
      #!/bin/sh
      # CI's dependency step: a fresh virtualenv with everything requirements.txt
      # asks for, resolved through the repository's pip.conf.
      set -eu
      cd "$(dirname "$0")/.."
      rm -rf .venv
      python3 -m venv .venv
      PIP_CONFIG_FILE=pip.conf .venv/bin/pip install --quiet -r requirements.txt
      .venv/bin/python -c 'import acme_billing as b; print("acme-billing", b.__version__, "from", b.ORIGIN)'
      SH
      chmod +x ci/install.sh
      ci/install.sh > ci/last-run.log 2>&1 || true

      echo "scenario ready — the service is /work/billing"
      echo
      echo "  CI's install step:  /work/billing/ci/install.sh"
      echo "  last night's run:   /work/billing/ci/last-run.log"
      echo "  internal index:     http://127.0.0.1:3141/simple/"
      echo "  public index:       http://127.0.0.1:8081/simple/"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # Both indexes rebuilt as the companies running them would have them,
      # plus what an attacker who has read your requirements.txt publishes next.
      rm -rf /srv/pypi
      mkdir -p /srv/pypi/internal/simple /srv/pypi/public/simple
      i=/srv/pypi/internal/simple p=/srv/pypi/public/simple
      mkwheel "$i" acme-billing 1.4.0 --requires 'acme-ledger>=2,<3' --requires 'retrying-lite>=1.2' --origin internal >/dev/null
      mkwheel "$i" acme-ledger 2.1.0 --origin internal >/dev/null
      mkwheel "$i" retrying-lite 1.2.0 --origin pypi >/dev/null
      mkwheel "$p" retrying-lite 1.2.0 --origin pypi >/dev/null
      mkwheel "$p" acme-billing 99.0.0 --origin "impostor on the public index" >/dev/null
      mkwheel "$p" acme-billing 1.4.0 --build 1 --requires 'acme-ledger>=2,<3' --origin "impostor on the public index" >/dev/null
      mkwheel "$p" acme-ledger 99.0.0 --origin "impostor on the public index" >/dev/null
      mkwheel "$p" acme-ledger 2.1.0 --build 1 --origin "impostor on the public index" >/dev/null

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
      if ! serve 3141 /srv/pypi/internal || ! serve 8081 /srv/pypi/public; then
        echo "not yet: the grader could not start the package indexes. Reset the scenario."
        exit 1
      fi

      if [ ! -f /work/billing/ci/install.sh ]; then
        echo "not yet: /work/billing/ci/install.sh is gone. CI runs it; reset the scenario."
        exit 1
      fi
      if ! grep -Eiq '^acme[-_.]billing([^a-z0-9_.-]|$)' /work/billing/requirements.txt 2>/dev/null; then
        echo "not yet: requirements.txt no longer asks for acme-billing. Renaming the"
        echo "dependency does not help — the internal index only has acme-billing, and an"
        echo "attacker can register any new name you pick just as easily."
        exit 1
      fi

      # CI's install, in a fresh checkout and a clean environment.
      cp -a /work/billing "$work/billing"
      rm -rf "$work/billing/.venv"
      rc=0
      (cd "$work/billing" && env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root PIP_DISABLE_PIP_VERSION_CHECK=1 sh ci/install.sh) > "$work/out" 2>&1 || rc=$?
      if [ ! -x "$work/billing/.venv/bin/python" ]; then
        echo "not yet: run from another checkout, install.sh did not build .venv there. Keep"
        echo "its paths relative to the repository — CI runs it in a fresh checkout."
        exit 1
      fi
      if [ "$rc" -ne 0 ]; then
        echo "not yet: CI's install step fails. pip says:"
        grep -Ev '^\s*$' "$work/out" | tail -3 || true
        if grep -q 'DO NOT MATCH THE HASHES' "$work/out"; then
          echo "Your hashes refused the impostor — but pip still chose it, so the build is now"
          echo "broken by whoever publishes next. pip must stop looking on the public index"
          echo "for internal names."
        fi
        exit 1
      fi

      report=$("$work/billing/.venv/bin/python" -c '
      import importlib, importlib.metadata as md
      for dist in ("acme-billing", "acme-ledger", "retrying-lite"):
          try:
              v = md.version(dist)
              o = getattr(importlib.import_module(dist.replace("-", "_")), "ORIGIN", "?")
          except Exception:
              v, o = "missing", "-"
          print(dist, v, o.replace(" ", "_"))
      ' 2>/dev/null || true)
      if [ -z "$report" ]; then
        echo "not yet: the grader could not import the installed packages from .venv."
        exit 1
      fi
      while read -r dist ver origin; do
        origin=${origin//_/ }
        case $dist:$origin in
          retrying-lite:*)
            if [ "$ver" = missing ]; then
              echo "not yet: retrying-lite was not installed."
              exit 1
            fi ;;
          *:internal) ;;
          *:impostor*)
            echo "not yet: CI installed $dist $ver from the public index — the impostor."
            case $ver in
              99.*) echo "pip compares every version on every index it is given and takes the"
                    echo "highest. Nothing in pip ranks one index above another." ;;
              *)    echo "The grader published its own $dist $ver on the public index, with a build"
                    echo "tag pip ranks above the internal file, so pinning or capping the version"
                    echo "does not help: a version number says nothing about who built the file." ;;
            esac
            [ "$dist" = acme-ledger ] && echo "acme-ledger is never named in requirements.txt — it is acme-billing's own dependency."
            exit 1 ;;
          *:-)
            echo "not yet: $dist was not installed. acme-billing needs it at runtime, so CI"
            echo "has to install the whole tree, from the internal index."
            exit 1 ;;
          *)
            echo "not yet: $dist is $ver, which is not what the internal index serves."
            exit 1 ;;
        esac
      done <<< "$report"

      echo "PASS — CI installs acme-billing and acme-ledger from the internal index, with"
      echo "the public one offering higher versions and same-version impostors of both."
---

## Why this exists

In 2021 Alex Birsan got code running inside Apple, Microsoft, PayPal and
thirty-odd other companies without phishing anyone. He read internal package
names out of leaked manifests and public JavaScript, published packages with
those names and a very high version number to the public registries, and
waited for build systems to install them. They did, because they were
configured to look in two places and take the newest.

## Harbor and the real world

Harbor stores images, not Python packages; the equivalent here is Artifactory,
Nexus or devpi in front of PyPI. Their *virtual* or *group* repositories merge
an internal repository with a remote proxy of the public one — the same
two-places-take-the-newest problem one layer down, unless they are configured
to exclude internal names from the remote side.
