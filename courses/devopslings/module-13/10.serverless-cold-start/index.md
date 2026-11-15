---
kind: lesson
title: "the function that times out on a cold start"
description: |
  quote, a Lambda function on floci, fetches a rate table inside its handler
  the first time it runs, and every fresh instance times out doing it. Measure
  what a cold start costs, move the fetch out of the request path, and set a
  timeout you can defend with the numbers.
name: serverless-cold-start
slug: serverless-cold-start
createdAt: "2026-10-15"
timingSensitive: true

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      F=http://floci:4566
      load-lambda-runtime
      docker network inspect lambda >/dev/null 2>&1 || docker network create lambda >/dev/null
      for f in $(curl -fsS $F/2015-03-31/functions 2>/dev/null | jq -r '.Functions[]?.FunctionName' || true); do
        curl -sS -o /dev/null -X DELETE "$F/2015-03-31/functions/$f" || true
      done
      curl -sS -o /dev/null "$F/" -d 'Action=DeleteRole&RoleName=quote&Version=2010-05-08' || true
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      rm -rf /root/quote
      install -d /root/quote/src /var/lib/devopslings
      cd /root/quote

      # pricing: answers with the rate table, slowly, and counts each fetch.
      docker run -d --name pricing --network lambda --restart unless-stopped \
        busybox:1.37.0 sh -c '
          mkdir -p /www/cgi-bin
          echo "{\"widget\": 4.5, \"gadget\": 12.0, \"gizmo\": 7.25}" > /www/rates.json
          cat > /www/cgi-bin/rates <<"CGI"
      #!/bin/sh
      sleep 3.5
      echo fetch >> /tmp/fetches
      printf "Content-Type: application/json\r\n\r\n"
      cat /www/rates.json
      CGI
          chmod +x /www/cgi-bin/rates
          exec httpd -f -p 8080 -h /www' >/dev/null

      cat > versions.tf <<'TF'
      terraform {
        required_providers {
          aws = {
            source  = "hashicorp/aws"
            version = "6.66.0"
          }
          archive = {
            source  = "hashicorp/archive"
            version = "2.8.1"
          }
        }
      }

      # floci, the local AWS API. Credentials come from the environment.
      provider "aws" {
        region                      = "us-east-1"
        skip_credentials_validation = true
        skip_requesting_account_id  = true
        skip_metadata_api_check     = true

        endpoints {
          iam    = "http://floci:4566"
          lambda = "http://floci:4566"
          sts    = "http://floci:4566"
        }
      }
      TF

      cat > main.tf <<'TF'
      data "archive_file" "quote" {
        type        = "zip"
        source_dir  = "${path.module}/src"
        output_path = "${path.module}/.build/quote.zip"
      }

      resource "aws_iam_role" "quote" {
        name = "quote"
        assume_role_policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect    = "Allow"
            Action    = "sts:AssumeRole"
            Principal = { Service = "lambda.amazonaws.com" }
          }]
        })
      }

      resource "aws_lambda_function" "quote" {
        function_name    = "quote"
        role             = aws_iam_role.quote.arn
        runtime          = "python3.12"
        handler          = "handler.handler"
        filename         = data.archive_file.quote.output_path
        source_code_hash = data.archive_file.quote.output_base64sha256
        memory_size      = 128
        timeout          = 3

        environment {
          variables = {
            RATES_URL = "http://pricing:8080/cgi-bin/rates"
          }
        }
      }
      TF

      cat > src/handler.py <<'PY'
      """quote: prices an order from the pricing service's rate table."""
      import json
      import os
      import urllib.request

      RATES_URL = os.environ["RATES_URL"]

      _rates = None


      def fetch_rates():
          # The pricing service returns the whole table, and it is slow.
          with urllib.request.urlopen(RATES_URL, timeout=10) as r:
              return json.load(r)


      def handler(event, context):
          global _rates
          if _rates is None:
              _rates = fetch_rates()
          item = event["item"]
          qty = int(event.get("qty", 1))
          return {"item": item, "qty": qty, "total": round(_rates[item] * qty, 2)}
      PY

      cat > invoke <<'SH'
      #!/bin/sh
      # invoke [JSON]: calls quote once and prints the reply and how long it took.
      body=${1:-'{"item": "widget", "qty": 2}'}
      curl -sS -X POST -d "$body" \
        -w '\n%{time_total}s  (HTTP %{http_code})\n' \
        http://floci:4566/2015-03-31/functions/quote/invocations
      SH
      chmod +x invoke

      cat > README <<'TXT'
      quote is a Lambda function (on floci, the local AWS API) deployed from
      this directory with OpenTofu. Every fresh instance of it times out:

        ./invoke '{"item": "widget", "qty": 2}'

      Fix it:

        - Measure a cold start and a warm call, and write what you measured
          in LATENCY, in milliseconds, one per line:
              cold_ms=<a call that started a new instance>
              warm_ms=<a call to an instance that was already running>
        - Take the rate fetch out of the request path. pricing is slow, and
          that will not change; the table it returns does not change either.
        - Set the function's timeout from your numbers: enough for a request,
          with headroom, and not a blanket number that hides the next hang.
        - Deploy with tofu apply; tofu plan shows no changes afterwards.
      TXT

      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      echo "scenario ready — /root/quote: ./invoke, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      if ! cd /root/quote 2>/dev/null; then
        echo "not yet: /root/quote is gone — reset the lesson to get it back"
        exit 1
      fi
      F=http://floci:4566/2015-03-31/functions
      G=/var/lib/devopslings/serverless-cold-start
      P=quote-coldprobe
      rm -rf $G
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }
      fetches() { docker exec pricing sh -c 'cat /tmp/fetches 2>/dev/null | wc -l' 2>/dev/null || echo 0; }
      # invoke FN BODY: reply in $G/out, headers in $G/hdr, wall time in $ms.
      invoke() {
        local t
        t=$(curl -sS -o $G/out -D $G/hdr -w '%{time_total}' -X POST -d "$2" "$F/$1/invocations" 2>/dev/null || echo 0)
        ms=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')
      }
      failed() { grep -qi '^x-amz-function-error' $G/hdr || ! jq -e '.total' $G/out >/dev/null 2>&1; }
      cleanup() { curl -sS -o /dev/null -X DELETE "$F/$P" 2>/dev/null || true; }
      trap cleanup EXIT
      cleanup

      if ! docker exec pricing true 2>/dev/null; then
        echo "not yet: the pricing container is not running. It is part of the scenario, not"
        echo "         something to change. Reset the lesson to get it back"
        exit 1
      fi

      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails:"
        err $G/init.log
        exit 1
      fi
      rc=0
      tofu plan -input=false -no-color -detailed-exitcode >$G/plan.log 2>&1 || rc=$?
      if [ "$rc" = 1 ]; then
        echo "not yet: tofu plan fails:"
        err $G/plan.log
        exit 1
      elif [ "$rc" = 2 ]; then
        echo "not yet: what is deployed is not what is in /root/quote; tofu plan wants:"
        grep -E '^  # ' $G/plan.log | sed 's/^/         /' || true
        echo "         Run tofu apply so the function runs the code you changed"
        exit 1
      fi
      cfg=$(curl -fsS "$F/quote/configuration" 2>/dev/null || true)
      if [ -z "$cfg" ]; then
        echo "not yet: there is no function called quote on floci"
        exit 1
      fi
      timeout=$(jq -r '.Timeout' <<<"$cfg")
      if [ "$timeout" -lt 3 ]; then
        echo "not yet: the timeout is ${timeout}s. floci gives a new instance its timeout plus 2s"
        echo "         to finish the init phase, and the rate fetch alone takes 3.5s, so below 3s"
        echo "         every cold start fails here. (AWS gives init its own 10s instead)"
        exit 1
      fi

      invoke quote '{"item": "gadget", "qty": 2}'
      if failed; then
        echo "not yet: quote fails when called: $(head -c 300 $G/out)"
        if grep -q 'TimedOut' $G/out; then
          echo "         ./invoke shows how long a call takes; time the first call to a new"
          echo "         instance and the ones after it, and compare them with the timeout"
        fi
        exit 1
      fi
      if ! jq -e '.total == 24' $G/out >/dev/null; then
        echo "not yet: quote prices 2 gadgets at $(jq -r .total $G/out); the rate table says 24.0"
        exit 1
      fi

      # A fresh copy of the deployed function, so the first call is a cold
      # start whatever state quote is in. Its 3s timeout is far more than a
      # request needs, and less than the rate fetch takes.
      code=$(curl -fsS "$F/quote" | jq -r '.Code.Location // empty')
      zip=$G/code.zip
      if [ -n "$code" ] && curl -fsS -o $zip "$code" 2>/dev/null; then :; else
        zip=$(tofu show -json | jq -r '.values.root_module.resources[]? | select(.address=="aws_lambda_function.quote") | .values.filename' | head -1)
        zip=$(realpath -m "$zip")
      fi
      jq -n --arg zip "$(base64 -w0 "$zip")" --argjson c "$cfg" --arg p $P '{
          FunctionName: $p, Runtime: $c.Runtime, Role: $c.Role, Handler: $c.Handler,
          MemorySize: $c.MemorySize, Timeout: 3, Code: {ZipFile: $zip},
          Environment: {Variables: ($c.Environment.Variables // {})}
        }' > $G/create.json
      if ! curl -fsS -o $G/create.out -X POST -H 'content-type: application/json' -d @$G/create.json "$F"; then
        echo "not yet: the grader could not deploy a copy of quote to measure it:"
        head -c 300 $G/create.out 2>/dev/null | sed 's/^/         /' || true
        exit 1
      fi

      f0=$(fetches)
      invoke $P '{"item": "widget", "qty": 2}'
      cold=$ms
      if failed; then
        echo "not yet: a cold start of quote spends more than 3s inside the handler:"
        echo "         $(head -c 200 $G/out)"
        echo "         The rate fetch still runs inside the handler, so its 3.5s counts against"
        echo "         the timeout. A longer timeout only hides that; the fetch has to happen"
        echo "         before the handler is called"
        exit 1
      fi
      f1=$(fetches)
      if [ "$f1" = "$f0" ]; then
        echo "not yet: a cold start of quote never called the pricing service."
        echo "         The rates have to come from pricing, fetched once per instance, not be"
        echo "         copied into the code where they go stale"
        exit 1
      fi
      warm=999999
      for i in 1 2 3; do
        invoke $P '{"item": "gizmo", "qty": 4}'
        if failed || ! jq -e '.total == 29' $G/out >/dev/null; then
          echo "not yet: a warm call to quote returned: $(head -c 200 $G/out)"
          exit 1
        fi
        [ "$ms" -lt "$warm" ] && warm=$ms
      done
      f2=$(fetches)
      if [ "$f2" != "$f1" ]; then
        echo "not yet: warm calls to quote fetched the rate table again ($((f2 - f1)) fetches in 3 calls)."
        echo "         The table does not change; fetch it once per instance"
        exit 1
      fi

      if [ ! -f LATENCY ]; then
        echo "not yet: there is no /root/quote/LATENCY with what you measured"
        exit 1
      fi
      s_cold=$(grep -Eo '^[[:space:]]*cold_ms[[:space:]]*=[[:space:]]*[0-9]+' LATENCY | grep -Eo '[0-9]+$' | head -1 || true)
      s_warm=$(grep -Eo '^[[:space:]]*warm_ms[[:space:]]*=[[:space:]]*[0-9]+' LATENCY | grep -Eo '[0-9]+$' | head -1 || true)
      if [ -z "$s_cold" ] || [ -z "$s_warm" ]; then
        echo "not yet: LATENCY needs a cold_ms=<number> line and a warm_ms=<number> line"
        exit 1
      fi
      if [ "$s_cold" -lt $((cold / 2)) ] || [ "$s_cold" -gt $((cold * 2)) ]; then
        echo "not yet: LATENCY says a cold start takes ${s_cold}ms; the grader measured ${cold}ms."
        echo "         A cold start is the first call to a new instance: change the function"
        echo "         (a redeploy or a configuration change retires running instances) and"
        echo "         time the next call"
        exit 1
      fi
      # Warm calls are milliseconds and jittery; what matters is that the
      # number is a warm one, an order of magnitude under the cold start.
      if [ "$s_warm" -gt $(( warm * 3 > 500 ? warm * 3 : 500 )) ]; then
        echo "not yet: LATENCY says a warm call takes ${s_warm}ms; the grader measured ${warm}ms."
        echo "         A warm call goes to an instance that is already running: time a few"
        echo "         calls in a row, right after a cold one"
        exit 1
      fi

      if [ $((timeout * 1000)) -gt $((cold * 3)) ]; then
        echo "not yet: the timeout is ${timeout}s. A cold start takes about ${cold}ms, and a warm"
        echo "         call ${warm}ms, so a request that has not answered after $((cold * 3 / 1000))s is"
        echo "         stuck, not slow. A timeout that large only holds the instance, and the"
        echo "         caller, while it waits"
        exit 1
      fi
      if [ $((timeout * 1000)) -lt $((warm * 2)) ]; then
        echo "not yet: the timeout is ${timeout}s, under twice what a warm call takes (${warm}ms)"
        exit 1
      fi
      rm -rf $G

      echo "PASS — quote fetches its rates once per instance before the first request,"
      echo "       a cold start (${cold}ms) and a warm call (${warm}ms) match LATENCY, and"
      echo "       the ${timeout}s timeout is sized from them."
---
