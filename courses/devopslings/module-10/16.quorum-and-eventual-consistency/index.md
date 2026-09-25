---
kind: lesson
title: "the write came back ok and the read cannot find it"
description: |
  The profile store has three nodes and no server-side replication: the client
  decides how many to write to and how many to read from. It writes to one and
  reads from one, and about a third of the time that is the same node. Nobody
  restarted anything. The numbers are the bug.
name: quorum-and-eventual-consistency
slug: quorum-and-eventual-consistency
createdAt: "2026-09-24"

sandbox:
  stack: db-stack
  service: redis

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /work/app /work/answers /work/nodes
      rm -f /work/answers/quorum.md

      # The store: three independent nodes that know nothing about each other.
      # Nothing replicates between them — the client is the only thing that
      # writes, which is what makes the quorum numbers the whole design.
      for p in 7001 7002 7003; do
        if ! redis-cli -p "$p" ping >/dev/null 2>&1; then
          redis-server --port "$p" --daemonize yes --save '' --appendonly no \
            --dir /work/nodes --dbfilename "node-$p.rdb" --logfile "/work/nodes/node-$p.log"
        fi
      done
      for p in 7001 7002 7003; do
        for _ in $(seq 1 40); do
          redis-cli -p "$p" ping 2>/dev/null | grep -q PONG && break
          sleep 0.25
        done
        redis-cli -p "$p" flushall >/dev/null
      done

      cat > /work/app/client.sh <<'CLIENT'
      #!/usr/bin/env bash
      # profile-store client.
      #
      # Three nodes, no server-side replication: this client is the only thing
      # that ever writes to them. A write goes to nodes until W of them have
      # acknowledged it; a read asks nodes until R of them have answered, and
      # takes the newest version it saw.
      #
      # Nodes are tried in a different order every time, so nothing is "the"
      # primary and load spreads.
      set -uo pipefail

      NODES="7001 7002 7003"
      N=3
      W=1    # acknowledgements required before a write is called done
      R=1    # nodes consulted before a read is answered

      order() { printf '%s\n' $NODES | shuf; }

      put() {
        key=$1; val=$2
        ver=$(date +%s%N)
        acks=0
        for p in $(order); do
          [ "$acks" -ge "$W" ] && break
          if redis-cli -p "$p" set "$key" "$ver|$val" >/dev/null 2>&1; then
            acks=$(( acks + 1 ))
          fi
        done
        if [ "$acks" -lt "$W" ]; then
          echo "write failed: $acks of $W nodes acknowledged" >&2
          return 1
        fi
        echo ok
      }

      get() {
        key=$1
        replies=0; best_ver=0; best=""
        for p in $(order); do
          [ "$replies" -ge "$R" ] && break
          if raw=$(redis-cli -p "$p" get "$key" 2>/dev/null); then
            replies=$(( replies + 1 ))
            [ -z "$raw" ] && continue
            ver=${raw%%|*}; val=${raw#*|}
            if [ "$ver" -gt "$best_ver" ]; then best_ver=$ver; best=$val; fi
          fi
        done
        if [ "$replies" -lt "$R" ]; then
          echo "read failed: $replies of $R nodes answered" >&2
          return 1
        fi
        printf '%s\n' "$best"
      }

      case "${1:-}" in
        put) put "$2" "$3" ;;
        get) get "$2" ;;
        *) echo "usage: client.sh put <key> <value> | client.sh get <key>" >&2; exit 2 ;;
      esac
      CLIENT
      chmod +x /work/app/client.sh

      cat > /work/answers/quorum.md <<'MD'
      # The profile store

      # The three numbers the client is configured with, after your fix.
      replication-factor-n: ?
      write-quorum-w: ?
      read-quorum-r: ?

      # One line: why does R + W > N make a read see the write that preceded
      # it? Say what the two sets of nodes have to have in common.
      why-the-inequality: ?

      # One line: with one of the three nodes down, what is the largest W you
      # can still acknowledge a write with, and what does that leave for R?
      with-one-node-down: ?
      MD

      echo "scenario ready"
      echo
      echo "  three nodes:  127.0.0.1:7001, :7002, :7003  (nothing replicates between them)"
      echo "  the client:   /work/app/client.sh"
      echo "  your answer:  /work/answers/quorum.md"
      echo
      echo "  /work/app/client.sh put user:1 alice"
      echo "  /work/app/client.sh get user:1"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      client=/work/app/client.sh
      ans=/work/answers/quorum.md

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$client" ]; then
        echo "not yet: $client is missing or empty. The client is what decides how many"
        echo "nodes a write reaches and a read consults."
        echo "Run 'devopslings reset quorum-and-eventual-consistency' to put it back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # The three nodes are the infrastructure, not the student's work: bring
      # back any this check stopped on a previous run before grading anything.
      ensure_nodes() {
        for p in 7001 7002 7003; do
          if ! redis-cli -p "$p" ping >/dev/null 2>&1; then
            redis-server --port "$p" --daemonize yes --save '' --appendonly no \
              --dir /work/nodes --dbfilename "node-$p.rdb" --logfile "/work/nodes/node-$p.log"
          fi
        done
        for p in 7001 7002 7003; do
          for _ in $(seq 1 40); do
            redis-cli -p "$p" ping 2>/dev/null | grep -q PONG && break
            sleep 0.25
          done
        done
      }
      stop_node() { redis-cli -p "$1" shutdown nosave >/dev/null 2>&1 || true; sleep 0.5; }

      ensure_nodes
      run=$(date +%s)
      trials=15

      # --- 1. a read has to see the write that preceded it --------------------
      miss=0
      for i in $(seq 1 $trials); do
        k="rw:$run:$i"; v="value-$i"
        if ! "$client" put "$k" "$v" >/dev/null 2>/tmp/q.err; then
          echo "not yet: the write itself failed with all three nodes up:"
          sed 's/^/    /' /tmp/q.err | head -2
          exit 1
        fi
        got=$("$client" get "$k" 2>/tmp/q.err || true)
        [ "$got" = "$v" ] || miss=$(( miss + 1 ))
      done
      if [ "$miss" -gt 0 ]; then
        echo "not yet: $miss of $trials reads could not see the write that came right before"
        echo "them, with all three nodes up and nothing restarted."
        echo
        echo "The nodes are fine. Ask how many of them a write reaches, how many a read"
        echo "consults, and how often those two sets can miss each other:"
        echo "    for p in 7001 7002 7003; do echo -n \"\$p: \"; redis-cli -p \$p get rw:$run:1; done"
        exit 1
      fi

      # --- 2. a write has to survive losing one node --------------------------
      for dead in 7001 7002 7003; do
        ensure_nodes
        for i in $(seq 1 $trials); do
          "$client" put "d$dead:$run:$i" "value-$i" >/dev/null 2>&1 || true
        done
        stop_node "$dead"
        lost=0; refused=""
        for i in $(seq 1 $trials); do
          got=$("$client" get "d$dead:$run:$i" 2>/tmp/q.err || true)
          if [ -z "$got" ] && [ -s /tmp/q.err ]; then
            refused=$(head -1 /tmp/q.err)
            break
          fi
          [ "$got" = "value-$i" ] || lost=$(( lost + 1 ))
        done
        ensure_nodes
        if [ -n "$refused" ]; then
          echo "not yet: with node $dead down, a read of a value written while all three were"
          echo "up refuses to answer at all:"
          echo "    $refused"
          echo
          echo "Two nodes are up and holding data. A read quorum that cannot be met when one"
          echo "of three nodes is gone makes the store unavailable on every single failure."
          exit 1
        fi
        if [ "$lost" -gt 0 ]; then
          echo "not yet: $lost of $trials values written while all three nodes were up could"
          echo "not be read back after node $dead stopped."
          echo
          echo "Nothing replicates between the nodes, so a value exists on exactly the nodes"
          echo "the client wrote it to. Work out how many that has to be for any single node"
          echo "to be losable — and note that a client which always talks to the same node"
          echo "first passes every test until that node is the one that stops."
          exit 1
        fi
      done

      # --- 3. and the store has to keep working with one node down ------------
      for dead in 7001 7002 7003; do
        ensure_nodes
        stop_node "$dead"
        miss=0; failed=""
        for i in $(seq 1 $trials); do
          k="down$dead:$run:$i"; v="value-$i"
          if ! "$client" put "$k" "$v" >/dev/null 2>/tmp/q.err; then
            failed=$(head -1 /tmp/q.err)
            break
          fi
          got=$("$client" get "$k" 2>/tmp/q.err || true)
          if [ -z "$got" ] && [ -s /tmp/q.err ]; then
            failed=$(head -1 /tmp/q.err)
            break
          fi
          [ "$got" = "$v" ] || miss=$(( miss + 1 ))
        done
        ensure_nodes
        if [ -n "$failed" ]; then
          echo "not yet: with node $dead down, the client refuses to serve at all:"
          echo "    $failed"
          echo
          echo "Two nodes are up and answering. A quorum that cannot be reached when one of"
          echo "three nodes is gone is not a quorum, it is a requirement for all of them."
          exit 1
        fi
        if [ "$miss" -gt 0 ]; then
          echo "not yet: with node $dead down, $miss of $trials reads could not see the write"
          echo "before them. The write and the read both have two nodes to work with — say"
          echo "how many of those two each of them has to touch for the sets to overlap."
          exit 1
        fi
      done

      # --- the numbers --------------------------------------------------------
      n=$(field replication-factor-n | grep -Eo '[0-9]+' | head -1 || true)
      w=$(field write-quorum-w       | grep -Eo '[0-9]+' | head -1 || true)
      r=$(field read-quorum-r        | grep -Eo '[0-9]+' | head -1 || true)
      if [ -z "$n" ] || [ -z "$w" ] || [ -z "$r" ]; then
        echo "not yet: replication-factor-n, write-quorum-w and read-quorum-r must each be a"
        echo "number."
        exit 1
      fi
      if [ "$n" != "3" ]; then
        echo "not yet: 'replication-factor-n:' says $n. N is how many nodes a key lives on,"
        echo "and the store has three."
        exit 1
      fi
      if [ $(( r + w )) -le "$n" ]; then
        echo "not yet: R + W = $(( r + w )), which is not greater than N = $n. Those numbers"
        echo "describe a store where a read and a write can touch disjoint sets of nodes."
        exit 1
      fi
      if [ "$w" -gt 2 ] || [ "$r" -gt 2 ]; then
        echo "not yet: W=$w and R=$r. With three nodes, anything above two stops working the"
        echo "moment one node does — and the check above already ran with each of them"
        echo "stopped in turn."
        exit 1
      fi

      why=$(field why-the-inequality | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(overlap|overlaps|overlapping|intersect|intersects|intersection|common|share|shares|shared|same node|at least one)\b'; then
        echo "not yet: 'why-the-inequality:' does not say what the two sets have in common."
        echo "R nodes and W nodes out of the same N. Say what has to be true of those two"
        echo "sets when their sizes add up to more than N, and why that is enough for the"
        echo "read to have the newest version in front of it."
        exit 1
      fi
      down=$(field with-one-node-down | tr 'A-Z' 'a-z')
      if ! printf '%s' "$down" | grep -Eq '(\b2\b|\btwo\b)'; then
        echo "not yet: 'with-one-node-down:' does not name the numbers. Two nodes are"
        echo "answering. Say the largest W that can still be acknowledged, and what R then"
        echo "has to be for R + W to still exceed N."
        exit 1
      fi

      echo "PASS — read-your-write holds with all three nodes up, values survive the loss of"
      echo "any one node, and the store still serves reads and writes with one down."
