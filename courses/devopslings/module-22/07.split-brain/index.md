---
kind: lesson
title: "Split brain: three members, two gone"
description: |
  A partition left etcd1 alone, the other two kept working, and then they
  died too. The on-call forced etcd1 to accept writes on its own. Now the
  other two will not even stay up. Put the cluster back together as one
  cluster, with every write anyone was told succeeded.
name: split-brain
slug: split-brain
createdAt: "2026-10-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      E() { local ep=$1; shift; etcdctl --endpoints="http://$ep:2379" --command-timeout=3s "$@"; }
      retry() { local _; for _ in $(seq 20); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done; "$@"; }

      retry E etcd1 put deploy/version 41
      # 13:02 — etcd1 is partitioned away. etcd2 and etcd3 are a majority and
      # carry on: a deploy records its version.
      node cut etcd1 back >/dev/null
      retry E etcd2 put deploy/version 42
      # Ordinary traffic carries on through the majority too. Nobody records it.
      E etcd2 put config/checkout-timeout-ms 800 >/dev/null
      E etcd3 put config/search-replicas 3 >/dev/null
      # 13:05 — etcd2 and etcd3 go down. The partition heals.
      node kill etcd2 >/dev/null
      node kill etcd3 >/dev/null
      node heal etcd1 back >/dev/null
      # 13:07 — etcd1 refuses writes: one member of three is no quorum. The
      # on-call restarts it as a cluster of one and disables payments.
      mkdir -p /ha/etcd
      cat > /ha/etcd/etcd1.env <<'ENV'
      # Added during the 13:05 incident to get etcd taking writes again.
      ETCD_FORCE_NEW_CLUSTER=true
      ENV
      docker restart devopslings-ha-etcd1 >/dev/null
      retry E etcd1 put flags/payments disabled

      cat > /ha/etcd/INCIDENT.txt <<'TXT'
      13:02  etcd1 partitioned from etcd2 and etcd3
      13:02  etcd2 and etcd3 carry on as a majority; services keep reading and
             writing their config through them as usual
      13:04  deploy pipeline wrote deploy/version through etcd2 — succeeded
      13:05  etcd2 and etcd3 down; partition healed
      13:06  etcd1 alone: "etcdserver: request timed out" on every write
      13:07  on-call: ETCD_FORCE_NEW_CLUSTER=true on etcd1, restarted it
      13:08  on-call: put flags/payments disabled — succeeded. Payments must
             stay disabled until the payments team says otherwise.
      13:20  etcd2 and etcd3 restarted. Both exited within seconds.
      TXT

      echo "scenario ready — etcd1 is a cluster of one, and etcd2 and etcd3 are down."
      echo
      E etcd1 member list
      echo
      echo "  what happened:          /ha/etcd/INCIDENT.txt"
      echo "  each member's settings: /ha/etcd/<member>.env  (applied on restart; see the module page)"
      echo "  ask one member:         etcdctl --endpoints=http://etcd1:2379 ..."
      echo "  member logs:            docker logs devopslings-ha-etcd2"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      members="etcd1 etcd2 etcd3"
      killed=""
      trap 'for n in $killed; do docker start "devopslings-ha-$n" >/dev/null 2>&1; done; true' EXIT
      E() { local ep=$1; shift; etcdctl --endpoints="http://$ep:2379" --command-timeout=3s "$@"; }

      for n in $members; do
        if [ "$(docker inspect -f '{{.State.Running}}' "devopslings-ha-$n")" != true ]; then
          echo "not yet: $n is not running ($(docker inspect -f '{{.State.Status}}' "devopslings-ha-$n"))."
          if docker logs --tail 60 "devopslings-ha-$n" 2>&1 | grep 'permanently removed from the cluster' >/dev/null; then
            echo "         Its log says: \"the member has been permanently removed from the cluster\"."
            echo "         Some member that believes it is the whole cluster told it so, and it shut down."
          fi
          exit 1
        fi
        if ! E "$n" endpoint health >/dev/null 2>&1; then
          echo "not yet: $n is running but not healthy: it cannot serve a quorum read."
          exit 1
        fi
      done

      ids=""
      for n in $members; do
        ml=$(E "$n" member list 2>/dev/null || true)
        started=$(grep -cE ', started, etcd[123], ' <<<"$ml" || true)
        if [ "$started" -ne 3 ] || [ "$(wc -l <<<"$ml")" -ne 3 ]; then
          echo "not yet: $n sees a cluster of $(wc -l <<<"$ml" | tr -d ' ') member(s), $started started:"
          sed 's/^/         | /' <<<"$ml"
          echo "         Every member has to see the same three."
          exit 1
        fi
        ids="$ids $(E "$n" endpoint status -w json | jq -r '.[0].Status.header.cluster_id')"
      done
      if [ "$(tr ' ' '\n' <<<"$ids" | grep -v '^$' | sort -u | wc -l)" -ne 1 ]; then
        echo "not yet: the members report different cluster ids:$ids. That is two clusters"
        echo "that happen to share member names."
        exit 1
      fi

      # Each member's own copy, not the leader's: they must have converged.
      # A member that has just joined may still be applying the log: allow it a few seconds.
      for key in deploy/version flags/payments; do
        for _ in $(seq 10); do
          vals=$(for n in $members; do echo "$n=$(E "$n" get "$key" --consistency=s --print-value-only 2>/dev/null)"; done)
          [ "$(cut -d= -f2- <<<"$vals" | sort -u | wc -l)" -eq 1 ] && break
          sleep 1
        done
        if [ "$(cut -d= -f2- <<<"$vals" | sort -u | wc -l)" -ne 1 ]; then
          echo "not yet: the members disagree about $key: $(tr '\n' ' ' <<<"$vals")"
          exit 1
        fi
      done
      v=$(E etcd1 get deploy/version --print-value-only)
      if [ "$v" != 42 ]; then
        echo "not yet: deploy/version is '${v:-missing}'. At 13:04 the deploy pipeline wrote 42 through"
        echo "etcd2, with etcd2 and etcd3 agreeing: a quorum write, acknowledged. That is the history"
        echo "this cluster had. The cluster you kept is etcd1's, which never saw it."
        exit 1
      fi
      for kv in config/checkout-timeout-ms=800 config/search-replicas=3; do
        got=$(E etcd1 get "${kv%%=*}" --print-value-only)
        if [ "$got" != "${kv#*=}" ]; then
          echo "not yet: ${kv%%=*} is '${got:-missing}', and the majority stored ${kv#*=} during the partition."
          echo "         Services kept writing through etcd2 and etcd3 (INCIDENT.txt, 13:02). Nobody wrote those"
          echo "         writes down, so re-entering the ones in the timeline cannot bring them back. Only the"
          echo "         majority's own data has them."
          exit 1
        fi
      done
      p=$(E etcd1 get flags/payments --print-value-only)
      if [ "$p" != disabled ]; then
        echo "not yet: flags/payments is '${p:-missing}'. The on-call's 13:08 write only ever existed on"
        echo "etcd1's one-member cluster. Payments must stay disabled: rejoining the real cluster"
        echo "does not carry it over, so it has to be written again, deliberately."
        exit 1
      fi
      for n in $members; do
        if grep -Eqs '^[[:space:]]*(export[[:space:]]+)?ETCD_FORCE_NEW_CLUSTER[[:space:]]*=[[:space:]]*"?(true|1)' "/ha/etcd/$n.env"; then
          echo "not yet: /ha/etcd/$n.env still sets ETCD_FORCE_NEW_CLUSTER. The next time $n restarts it"
          echo "throws away the other members again, and they shut down as soon as it tells them so."
          exit 1
        fi
      done
      echo "one cluster of three, every member agrees: deploy/version=42, flags/payments=disabled"

      # Lose two again: the survivor must refuse, and the cluster must recover.
      killed="etcd2 etcd3"
      docker kill devopslings-ha-etcd2 devopslings-ha-etcd3 >/dev/null
      if E etcd1 put quorum/probe "$(date +%s)" >/dev/null 2>&1; then
        echo "not yet: with etcd2 and etcd3 dead, etcd1 accepted a write on its own."
        exit 1
      fi
      docker start devopslings-ha-etcd2 devopslings-ha-etcd3 >/dev/null
      killed=""
      ok=""
      for _ in $(seq 30); do
        E etcd1 put quorum/probe "$(date +%s)" >/dev/null 2>&1 && { ok=1; break; }
        sleep 1
      done
      if [ -z "$ok" ]; then
        echo "not yet: after etcd2 and etcd3 came back, the cluster did not take writes within 30s."
        exit 1
      fi
      E etcd1 del quorum/probe >/dev/null
      echo "two members killed: etcd1 refused writes; both back: writes resumed"
      echo
      echo "PASS — one cluster, one history, and it still refuses to work without a quorum."
