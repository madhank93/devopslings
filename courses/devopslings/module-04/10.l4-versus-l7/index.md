---
kind: lesson
title: "four requirements, one load balancer layer each"
description: |
  L7 sees more, so L7 sounds better. It also terminates the connection, which
  costs you the client's address, the protocol's own framing, and a good deal
  of throughput. Four requirements, one choice each, and the grader checks the
  reason — because being right for the wrong reason does not survive the fifth
  requirement.
name: l4-versus-l7
slug: l4-versus-l7
createdAt: "2026-08-08"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e
      install -d /srv/reqs /root/answers

      cat > /srv/reqs/case-1-checkout.md <<'CASE'
      # Case 1 — the checkout front end

      Public HTTPS. Certificates are managed centrally and must be terminated
      before traffic reaches the application, because the application team is
      not permitted to hold the private key.

      Requests to /api/ go to the api pool, everything else to the web pool.
      The two pools scale independently and the split changes most sprints.

      Peak: 4,000 requests/second, average response 12 KB.
      A per-request X-Request-Id header must be added if the client did not
      send one.
      CASE

      cat > /srv/reqs/case-2-ingest.md <<'CASE'
      # Case 2 — the telemetry ingest tier

      Devices in the field open a long-lived TCP connection and stream a binary
      framing protocol of our own design. Not HTTP. There are no requests and no
      headers; a connection is a stream that lasts for days.

      Peak: 90,000 concurrent connections, 12 Gbit/s aggregate.

      The device fleet cannot be changed for at least eighteen months.
      CASE

      cat > /srv/reqs/case-3-audit.md <<'CASE'
      # Case 3 — the regulated internal service

      An internal HTTP service behind a load balancer. Compliance requires that
      every request is logged by the *application* with the true source address
      of the calling host, and auditors have rejected a design where the
      application logs the balancer's address and correlates against a separate
      balancer log.

      Traffic is modest: 200 requests/second. No TLS — this runs on a private
      segment. No content-based routing is needed; any backend can serve any
      request.
      CASE

      cat > /srv/reqs/case-4-database.md <<'CASE'
      # Case 4 — the read replicas

      A PostgreSQL primary with six read replicas. The team wants the balancer
      to send read-only transactions to the replicas and everything else to the
      primary, so that applications can point at one address and stop caring.

      The protocol is the PostgreSQL wire protocol over TCP, optionally with
      TLS. Whether a transaction is read-only is not known from the connection —
      it is a property of the statements sent inside it, and a single connection
      carries many transactions over its lifetime.
      CASE

      cat > /root/answers/verdict.md <<'ANS'
      # One line per case. Replace every ? with your answer.
      #
      #   layer=    l4 | l7
      #   because=  termination | routing | sourceaddress | throughput | protocol
      #
      # Pick the constraint that actually decides it — the one that would still
      # decide it if everything else in the case changed.

      case-1: layer=? because=?
      case-2: layer=? because=?
      case-3: layer=? because=?
      case-4: layer=? because=?
      ANS

      cat > /root/questions.txt <<'Q'
      Four services, in /srv/reqs/. Each needs a load balancer. For each one,
      pick the layer and name the constraint that decided it.

        cat /srv/reqs/case-1-checkout.md

      Write your answers in /root/answers/verdict.md, which has the four lines
      and the allowed values already.

      One of these four is a case where L7 cannot do what is being asked at all,
      no matter how it is configured. Finding that one is most of the exercise.

      Nothing needs to be installed or configured. This is graded on the
      decisions and the reasons.
      Q

      echo "scenario ready — four cases in /srv/reqs, answers in /root/answers/verdict.md"
      ls /srv/reqs | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ans=/root/answers/verdict.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      fail=0
      while read -r n want_layer want_token; do
        line=$(grep -E "^case-$n:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: no 'case-$n:' line in $ans"
          exit 1
        fi

        gl=$(printf '%s' "$line" | sed -n 's/.*layer=\([A-Za-z0-9]*\).*/\1/p'  | tr 'A-Z' 'a-z')
        gt=$(printf '%s' "$line" | sed -n 's/.*because=\([A-Za-z]*\).*/\1/p' | tr 'A-Z' 'a-z')

        if [ -z "$gl" ] || [ "$gl" = "?" ]; then
          echo "not yet: case-$n has no layer — it must be l4 or l7"
          exit 1
        fi
        case "$gl" in
          l4|l7) ;;
          *) echo "not yet: case-$n says layer='$gl', which is not l4 or l7"; exit 1 ;;
        esac
        if [ -z "$gt" ] || [ "$gt" = "?" ]; then
          echo "not yet: case-$n has no 'because=' token"
          exit 1
        fi
        case "$gt" in
          termination|routing|sourceaddress|throughput|protocol) ;;
          *) echo "not yet: case-$n uses '$gt', which is not one of the five tokens"; exit 1 ;;
        esac

        if [ "$gl" != "$want_layer" ]; then
          fail=1
          echo "not yet: case-$n — you said $gl."
          case "$n" in
            1) echo "         Read what has to happen to the TLS session and what decides"
               echo "         which pool a request goes to. Both need the request itself." ;;
            2) echo "         There are no requests in this protocol. Ask what an L7"
               echo "         balancer would parse, and what it would cost at 12 Gbit/s"
               echo "         across 90,000 connections it has to terminate twice." ;;
            3) echo "         An L7 balancer terminates the client's connection and opens"
               echo "         its own. Ask what source address the backend then sees, and"
               echo "         whether a header carrying the original is what the auditors"
               echo "         said they would accept." ;;
            4) echo "         Look again at whether the balancer can know, at connection"
               echo "         time, what it is being asked to route on." ;;
          esac
        elif [ "$gt" != "$want_token" ]; then
          fail=1
          echo "not yet: case-$n — the layer is right, '$gt' is not the constraint that"
          echo "         decided it."
          case "$n" in
            1) echo "         Several things here need L7. Only one of them is impossible"
               echo "         to do anywhere else in the stack: the key may not reach the"
               echo "         application, so the connection must end at the balancer." ;;
            2) echo "         It is not that L7 would be slow. It is that there is nothing"
               echo "         for it to parse — the framing is ours and no balancer knows"
               echo "         it." ;;
            3) echo "         The volume is trivial and there is no TLS and no routing."
               echo "         What is left is the one thing terminating the connection"
               echo "         destroys." ;;
            4) echo "         The routing key does not exist at connection time. It is"
               echo "         inside statements sent later, on a connection that carries"
               echo "         many transactions — so no balancer can classify it." ;;
          esac
        fi
      done <<'EXPECT'
      1 l7 termination
      2 l4 protocol
      3 l4 sourceaddress
      4 l4 protocol
      EXPECT

      if [ "$fail" -ne 0 ]; then
        exit 1
      fi

      echo "PASS — four layers chosen and four constraints named, including the case"
      echo "       where L7 cannot answer the question at all."
