---
kind: lesson
title: "Every commit rebuilds the world, and the image is 1 GB"
description: |
  CI takes six minutes to build an image that changed by one line, and the
  result is a gigabyte of mostly build toolchain. Fix both with the same two
  ideas: order layers by how often they change, and don't ship what you only
  needed to compile.
name: layer-cache-and-size
slug: layer-cache-and-size
createdAt: "2026-07-31"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      cat > requirements.txt <<'REQ'
      flask==3.0.3
      REQ

      cat > app.py <<'PY'
      from flask import Flask

      app = Flask(__name__)

      @app.get("/health")
      def health():
          return {"status": "ok", "version": "1.0.0"}

      if __name__ == "__main__":
          app.run(host="0.0.0.0", port=8080)
      PY

      # The Dockerfile as written by someone who has not yet been bitten:
      # a full toolchain in the shipping image, and COPY . . before the
      # dependency install, which invalidates the cache on every source change.
      cat > Dockerfile <<'DOCKER'
      FROM python:3.12

      WORKDIR /app

      RUN apt-get update && apt-get install -y build-essential gcc g++ make

      COPY . .

      RUN pip install -r requirements.txt

      CMD ["python3", "app.py"]
      DOCKER

      cat > .dockerignore <<'IGNORE'
      IGNORE

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "Measure the starting point:"
      echo "  time docker build -t devopslings-size ."
      echo "  docker images devopslings-size"
      echo "  # then touch app.py and build again — watch what gets re-run"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      img=devopslings-size-check
      ctr=devopslings-size-check
      max_mb=250

      cleanup() { docker rm -f "$ctr" >/dev/null 2>&1 || true; }
      trap cleanup EXIT
      cleanup

      if ! docker build -q -t "$img" . >/dev/null 2>&1; then
        echo "not yet: the image does not build — run 'docker build -t $img .' to see why"
        exit 1
      fi

      # 1. Size. The toolchain is a build-time need, not a runtime one.
      bytes=$(docker image inspect "$img" --format '{{.Size}}')
      mb=$(( bytes / 1000000 ))
      if [ "$mb" -gt "$max_mb" ]; then
        echo "not yet: the image is ${mb} MB, target is under ${max_mb} MB — what is in there that you only needed to build it?"
        exit 1
      fi

      # 2. Cache behaviour. Change a line of application source, the way a
      #    commit would, and rebuild.
      #
      #    This is checked by looking for evidence that pip actually ran, not by
      #    timing the build. Timing would be the obvious approach and it is a
      #    bad one: installing Flask takes about four seconds either way, so any
      #    threshold that separated cached from uncached here would be measuring
      #    the machine rather than the Dockerfile. `Collecting flask` appears in
      #    the build output only when the dependency layer was genuinely
      #    rebuilt, on any hardware.
      cp app.py .app.py.bak
      printf '\n# cache probe %s\n' "$(date +%s)" >> app.py
      out=$(docker build --progress=plain -t "$img" . 2>&1 || true)
      mv .app.py.bak app.py

      if printf '%s' "$out" | grep -q 'Collecting flask'; then
        echo "not yet: changing one line of app.py re-installed the dependencies — your COPY is invalidating the layer that installs them"
        exit 1
      fi

      # 3. It still has to work. Both fixes are easy to do in ways that produce
      #    a small image that cannot run.
      docker rm -f "$ctr" >/dev/null 2>&1 || true
      docker run -d --name "$ctr" -p 18080:8080 "$img" >/dev/null
      ok=""
      for _ in $(seq 20); do
        if curl -fsS --max-time 2 http://127.0.0.1:18080/health 2>/dev/null | grep -q '"ok"'; then
          ok=1; break
        fi
        sleep 1
      done
      if [ -z "$ok" ]; then
        echo "not yet: the image is ${mb} MB with a working cache, but /health never answered — it has to still run"
        docker logs "$ctr" 2>&1 | tail -5
        exit 1
      fi

      echo "PASS — ${mb} MB, dependency layer survives a source change, and /health still answers."
---
