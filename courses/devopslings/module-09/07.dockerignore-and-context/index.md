---
kind: lesson
title: "the build spends most of its time before the first instruction runs"
description: |
  Every build uploads the working directory to the daemon before it reads the
  Dockerfile. This one uploads a hundred megabytes of things the image does not
  need. Learn what the build context is, what .dockerignore does to it, and why
  narrowing your COPY lines changes nothing.
name: dockerignore-and-context
slug: dockerignore-and-context
createdAt: "2026-09-01"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      docker image rm -f devopslings-context >/dev/null 2>&1 || true
      rm -rf .git node_modules web fixtures tmp .venv templates
      rm -f .dockerignore

      mkdir -p templates web/dist web/node_modules fixtures tmp \
               .git/objects/pack .venv/lib/python3.12/site-packages

      cat > app.py <<'PY'
      index = open("templates/index.html").read().strip()
      bundle = open("web/dist/bundle.js").read().strip()
      print(f"index: {index}")
      print(f"bundle: {bundle}")
      PY

      echo '<h1>devopslings</h1>' > templates/index.html
      echo 'console.log("bundle v3");' > web/dist/bundle.js

      cat > Dockerfile <<'DOCKER'
      FROM python:3.12-slim
      WORKDIR /app
      COPY . .
      CMD ["python3", "app.py"]
      DOCKER

      # What a working checkout accumulates: history, the frontend's
      # dependencies, test data, a virtualenv, and last week's build log. None of
      # it is in the image, and all of it is in the build context.
      dd if=/dev/zero of=.git/objects/pack/pack-8f31a2.pack bs=1024 count=40960 2>/dev/null
      for i in $(seq 1 60); do
        mkdir -p "web/node_modules/pkg-$i"
        dd if=/dev/zero of="web/node_modules/pkg-$i/index.js" bs=1024 count=600 2>/dev/null
      done
      dd if=/dev/zero of=fixtures/events.jsonl bs=1024 count=15360 2>/dev/null
      dd if=/dev/zero of=.venv/lib/python3.12/site-packages/blob.bin bs=1024 count=8192 2>/dev/null
      dd if=/dev/zero of=tmp/build.log bs=1024 count=3072 2>/dev/null

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it:"
      echo "  docker build -t devopslings-context ."
      echo "  # read the 'transferring context' line before anything is built"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      img=devopslings-context
      probe=devopslings-context-probe
      limit_kb=1024

      tmpdir=$(mktemp -d)
      cleanup() {
        docker image rm -f "$probe" >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
      }
      trap cleanup EXIT

      for f in Dockerfile app.py templates/index.html web/dist/bundle.js; do
        if [ ! -f "$f" ]; then
          echo "not yet: $f is missing from $(pwd) — the app needs it to run"
          exit 1
        fi
      done

      # Measure the context the way the daemon sees it: everything .dockerignore
      # lets through, regardless of which of it any COPY line asks for. The probe
      # Dockerfile lives outside the directory so it is not part of what it
      # measures.
      printf 'FROM alpine:3.20\nCOPY . /ctx\n' > "$tmpdir/probe.Dockerfile"
      if ! docker build -q -f "$tmpdir/probe.Dockerfile" -t "$probe" . >/dev/null 2>&1; then
        echo "not yet: could not read the build context — does 'docker build .' work here?"
        exit 1
      fi

      size_kb=$(docker run --rm "$probe" du -sk /ctx | awk '{print $1}')
      if [ "${size_kb:-0}" -ge "$limit_kb" ]; then
        echo "not yet: the build context is ${size_kb} KB, and it needs to be under ${limit_kb} KB."
        echo "The biggest things still being sent:"
        docker run --rm "$probe" sh -c 'du -sk /ctx/* /ctx/.[!.]* 2>/dev/null | sort -rn | head -5' \
          | awk '{printf "    %s KB  %s\n", $1, $2}' || true
        echo "Every one of them is uploaded before the first instruction runs, whether"
        echo "or not a COPY asks for it."
        exit 1
      fi

      docker image rm -f "$img" >/dev/null 2>&1 || true
      if ! out=$(docker build -t "$img" . 2>&1); then
        echo "not yet: the image no longer builds:"
        printf '%s\n' "$out" | tail -12 | sed 's/^/    /'
        echo "Something the Dockerfile needs is being excluded."
        exit 1
      fi

      expected='index: <h1>devopslings</h1>
      bundle: console.log("bundle v3");'
      got=$(docker run --rm "$img" 2>&1 || true)
      if [ "$got" != "$expected" ]; then
        echo "not yet: the image builds but does not run correctly. It said:"
        printf '%s\n' "$got" | tail -10 | sed 's/^/    /'
        echo "Expected:"
        printf '%s\n' "$expected" | sed 's/^/    /'
        echo "An exclusion that is too wide takes a file the app reads at runtime."
        exit 1
      fi

      echo "PASS — the context is ${size_kb} KB and the image still serves both files."
---
