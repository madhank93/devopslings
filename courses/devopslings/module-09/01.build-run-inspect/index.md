---
kind: lesson
title: "the container ran, the report is gone"
description: |
  Last night's job built, ran, printed "wrote /out/report.txt" and exited. There
  is no report.txt on the host. Learn what a container's filesystem is, where
  that file actually went, and the two ways to get it out.
name: build-run-inspect
slug: build-run-inspect
createdAt: "2026-08-31"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      # Start every attempt from nothing: the learner writes the Dockerfile, so
      # unlike a lesson that ships one, a previous attempt's build is not
      # overwritten by anything below.
      docker rm -f report-run devopslings-report-probe >/dev/null 2>&1 || true
      docker image rm -f devopslings-report >/dev/null 2>&1 || true
      rm -f Dockerfile
      rm -rf out recovered

      cat > orders.csv <<'CSV'
      id,customer,amount
      1001,acme,420
      1002,globex,150
      1003,initech,613
      1004,umbrella,107
      CSV

      cat > report.py <<'PY'
      #!/usr/bin/env python3
      """Summarise the day's orders into a report."""
      import csv
      import os

      SRC = "/app/orders.csv"
      OUT = "/out/report.txt"

      with open(SRC) as f:
          rows = list(csv.DictReader(f))

      total = sum(int(r["amount"]) for r in rows)

      os.makedirs(os.path.dirname(OUT), exist_ok=True)
      with open(OUT, "w") as f:
          f.write(f"orders: {len(rows)}\n")
          f.write(f"total: {total}\n")

      print(f"wrote {OUT}", flush=True)
      PY

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "You need to write the Dockerfile. The report generator expects"
      echo "orders.csv at /app/orders.csv and writes /out/report.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      img=devopslings-report
      ctr=report-run
      probe=devopslings-report-probe

      cleanup() {
        docker rm -f "$probe" >/dev/null 2>&1 || true
        rm -rf .verify
      }
      trap cleanup EXIT
      cleanup

      expected='orders: 4
      total: 1290'

      if [ ! -f Dockerfile ]; then
        echo "not yet: no Dockerfile in $(pwd) — that is the first thing to write"
        exit 1
      fi

      if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "not yet: no image tagged $img. Build one: docker build -t $img ."
        exit 1
      fi

      # Everything below trusts the image, not the host files: a report typed by hand
      # is not a report a container produced. Run one and keep what it wrote.
      mkdir -p .verify
      if ! docker run --name "$probe" "$img" >.verify/run.log 2>&1; then
        echo "not yet: $img builds, but a container from it exits non-zero:"
        sed 's/^/    /' .verify/run.log
        exit 1
      fi

      if ! docker cp "$probe:/out/report.txt" .verify/report.txt >/dev/null 2>&1; then
        echo "not yet: a container from $img ran and exited 0, but left no /out/report.txt."
        echo "It printed:"
        sed 's/^/    /' .verify/run.log
        echo "Is report.py what the image actually runs?"
        exit 1
      fi

      produced=$(cat .verify/report.txt)
      if [ "$produced" != "$expected" ]; then
        echo "not yet: $img produces a report that is not the one report.py writes."
        echo "It produced:"
        printf '%s\n' "$produced" | sed 's/^/    /'
        echo "Expected:"
        printf '%s\n' "$expected" | sed 's/^/    /'
        echo "Check that orders.csv and report.py both reached the image unedited."
        exit 1
      fi

      if ! docker container inspect "$ctr" >/dev/null 2>&1; then
        echo "not yet: no container named $ctr. The run that wrote the report has to"
        echo "still exist to be inspected, so run it without --rm:"
        echo "  docker run --name $ctr $img"
        exit 1
      fi

      status=$(docker container inspect -f '{{.State.Status}}' "$ctr")
      code=$(docker container inspect -f '{{.State.ExitCode}}' "$ctr")
      if [ "$status" = "running" ]; then
        echo "not yet: $ctr is still running — the report job exits on its own, so wait"
        echo "for it (docker wait $ctr) rather than grading a run in progress"
        exit 1
      fi
      if [ "$code" != "0" ]; then
        echo "not yet: $ctr exited $code. Read what it said (docker logs $ctr) and run it again."
        exit 1
      fi

      if [ ! -f recovered/report.txt ]; then
        echo "not yet: nothing at recovered/report.txt. $ctr has exited, but its"
        echo "filesystem is still on disk — the report is in there:"
        echo "  mkdir -p recovered && docker cp $ctr:/out/report.txt recovered/report.txt"
        exit 1
      fi
      if [ "$(cat recovered/report.txt)" != "$produced" ]; then
        echo "not yet: recovered/report.txt does not match what the image writes."
        echo "Copy it out of the container rather than retyping it."
        exit 1
      fi

      if [ ! -f out/report.txt ]; then
        echo "not yet: nothing at out/report.txt. Rescuing the file after the fact is"
        echo "the recovery; the next run should land it on the host by itself:"
        echo "  mkdir -p out && docker run --rm -v \"\$(pwd)/out:/out\" $img"
        exit 1
      fi
      if [ "$(cat out/report.txt)" != "$produced" ]; then
        echo "not yet: out/report.txt does not match what the image writes."
        echo "It should be the output of a run, not a copy you edited."
        exit 1
      fi

      echo "PASS — image builds, $ctr's filesystem gave up the report it wrote, and a"
      echo "mounted run put the next one on the host."
---
