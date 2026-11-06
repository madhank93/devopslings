---
kind: lesson
title: "the ledger volume is older than the code"
description: |
  The payments network and the ledger volume were made by hand years ago, and
  the ledger holds data nobody can recreate. Bring both under OpenTofu so
  that a plan is empty, without destroying, recreating or emptying either of
  them.
name: import-what-exists
slug: import-what-exists
createdAt: "2026-10-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      docker network rm payments-net >/dev/null 2>&1 || true
      docker volume rm ledger >/dev/null 2>&1 || true
      rm -rf /root/payments
      install -d /root/payments /var/lib/devopslings
      cd /root/payments

      docker network create --driver bridge --internal \
        --subnet 10.42.0.0/24 --gateway 10.42.0.1 \
        --label team=payments --label tier=data payments-net >/dev/null
      docker volume create --label team=payments --label backup=nightly ledger >/dev/null
      docker run --rm -v ledger:/data busybox:1.37.0 sh -c \
        'for i in $(seq 1 500); do echo "txn-$i,$((i * 37 % 1000)).00,settled"; done > /data/ledger.csv' >/dev/null

      cat > versions.tf <<'TF'
      terraform {
        required_providers {
          docker = {
            source  = "kreuzwerker/docker"
            version = "4.6.0"
          }
        }
      }

      provider "docker" {}
      TF

      cat > README <<'TXT'
      payments-net (a docker network) and ledger (a docker volume) were
      created by hand. ledger holds 500 settled transactions that exist
      nowhere else.

      Bring both under this configuration:

        - docker_network.payments manages payments-net
        - docker_volume.ledger manages ledger
        - tofu plan shows no changes afterwards

      Neither may be destroyed or recreated along the way, and the data in
      ledger must survive. docker network inspect / docker volume inspect
      show how they were made.
      TXT

      {
        echo "net=$(docker network inspect -f '{{.Id}}' payments-net)"
        echo "vol=$(docker volume inspect -f '{{.CreatedAt}}' ledger)"
      } > /var/lib/devopslings/import-what-exists.env
      tofu init -input=false >/dev/null
      echo "scenario ready — /root/payments: payments-net and ledger exist, the code does not"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      if ! cd /root/payments 2>/dev/null || [ ! -f /var/lib/devopslings/import-what-exists.env ]; then
        echo "not yet: /root/payments is gone — reset the lesson to get it back"
        exit 1
      fi
      . /var/lib/devopslings/import-what-exists.env
      G=/var/lib/devopslings/import-what-exists
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      now_vol=$(docker volume inspect -f '{{.CreatedAt}}' ledger 2>/dev/null || true)
      rows=$(docker run --rm -v ledger:/data busybox:1.37.0 sh -c 'grep -c settled /data/ledger.csv 2>/dev/null || true' 2>/dev/null || true)
      if [ "$now_vol" != "$vol" ] || [ "${rows:-0}" != 500 ]; then
        if [ -z "$now_vol" ]; then
          echo "not yet: the ledger volume is gone, and the 500 transactions with it."
        elif [ "$now_vol" != "$vol" ]; then
          echo "not yet: ledger was destroyed and recreated (created $now_vol, not $vol)."
          echo "         It now holds ${rows:-0} of the 500 transactions."
        else
          echo "not yet: ledger is the original volume but holds ${rows:-0} of its 500 transactions."
        fi
        echo "         A replacement in a plan (-/+) destroys first. Reset the lesson to get the data back"
        exit 1
      fi
      now_net=$(docker network inspect -f '{{.Id}}' payments-net 2>/dev/null || true)
      if [ "$now_net" != "$net" ]; then
        echo "not yet: payments-net ${now_net:+was destroyed and recreated}${now_net:-is gone}."
        echo "         Anything attached to the old network lost its connection. Reset the lesson"
        exit 1
      fi

      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails:"
        err $G/init.log
        exit 1
      fi
      rc=0
      tofu plan -input=false -no-color -detailed-exitcode -out=$G/plan >$G/plan.log 2>&1 || rc=$?
      if [ "$rc" = 1 ]; then
        echo "not yet: tofu plan fails:"
        err $G/plan.log
        exit 1
      fi
      pj=$(tofu show -json -no-color $G/plan)
      for a in docker_network.payments docker_volume.ledger; do
        if ! jq -e --arg a "$a" '.configuration.root_module.resources[]? | select(.address==$a)' <<<"$pj" >/dev/null; then
          echo "not yet: the configuration has no $a block"
          exit 1
        fi
      done
      if grep -qs 'ignore_changes' ./*.tf; then
        echo "not yet: the code uses lifecycle ignore_changes. That quiets the plan by not comparing,"
        echo "         so the code still does not say how payments-net and ledger were made. Remove it"
        echo "         and write the attributes docker network inspect / docker volume inspect show"
        exit 1
      fi
      if [ "$rc" = 2 ]; then
        echo "not yet: tofu plan still wants changes:"
        jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] or .change.importing) | "           " + (if .change.actions == ["no-op"] then "import" else (.change.actions | join("/")) end) + " \(.address)" + (if (.change.replace_paths // []) == [] then "" else "  (replaced because of: \(.change.replace_paths | map(.[0] | tostring) | unique | join(", ")))" end) + (if .change.importing then "  [import pending]" else "" end)' <<<"$pj" || true
        if jq -e '[.resource_changes[]? | select(.change.actions | index("create"))] | length > 0' <<<"$pj" >/dev/null; then
          echo "         a planned replacement or create of something that already exists means the"
          echo "         code does not describe it exactly; every attribute it was made with has to match"
        fi
        if jq -e '[.resource_changes[]? | select(.change.importing)] | length > 0' <<<"$pj" >/dev/null; then
          echo "         an import block is planned but not applied: import only lands in state on apply"
        fi
        exit 1
      fi
      for p in "docker_network.payments payments-net" "docker_volume.ledger ledger"; do
        set -- $p
        sn=$(jq -r --arg a "$1" '[.prior_state.values.root_module.resources[]? | select(.address==$a) | .values.name][0] // empty' <<<"$pj")
        if [ "$sn" != "$2" ]; then
          echo "not yet: state's $1 is ${sn:-not there}, not $2"
          exit 1
        fi
      done
      rm -rf $G

      echo "PASS — payments-net and ledger are in state with their original identities, the"
      echo "       500 transactions are intact, and the plan is empty."
---
