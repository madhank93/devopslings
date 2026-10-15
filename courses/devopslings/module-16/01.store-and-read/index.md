---
kind: lesson
title: "The API key is baked into the image"
description: |
  greeter calls a partner's API with a key, and the key is an ENV line in its
  Dockerfile. Anyone who can pull the image can read it. Put the key in
  OpenBao and have greeter fetch it when it starts, so the value is in no
  file, no image layer and no environment.
name: store-and-read
slug: store-and-read
createdAt: "2026-10-14"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      L=../../courses/devopslings/module-16/01.store-and-read
      G=$L/greeter.compose.yaml
      S=../../scratch/store-and-read
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }

      mkdir -p "$S"
      cp "$L/starter/Dockerfile" "$L/starter/app.py" "$S/"

      # A key stored by an earlier attempt would make the first step look done.
      bao kv metadata delete secret/greeter/partner-api >/dev/null 2>&1 || true

      # greeter gets its own token, allowed to read only its own secrets. Which
      # token an app should hold is the next lesson; this one is about the key.
      printf '%s\n' 'path "secret/data/greeter/*" {' '  capabilities = ["read"]' '}' \
        | bao policy write greeter - >/dev/null
      token=$(bao token create -policy=greeter -field=token | tr -d '\r')

      # .env is the student's file and outlives `compose down`, so it is reset
      # here. COMPOSE_FILE layers greeter over the stack for a plain
      # `docker compose` run from this directory.
      cat > .env <<ENV
      COMPOSE_FILE=compose.yaml:$G
      COMPOSE_PROJECT_NAME=devopslings-ci-stack
      GREETER_BAO_TOKEN=$token
      ENV

      dc up -d --build --force-recreate greeter >/dev/null 2>&1
      for _ in $(seq 40); do
        curl -fsS --max-time 2 http://127.0.0.1:18160/status >/dev/null 2>&1 && break
        sleep 0.5
      done

      echo "scenario ready — greeter is up, holding the key from its Dockerfile."
      echo
      curl -fsS --max-time 3 http://127.0.0.1:18160/status || true
      echo
      echo
      echo "  the code:  scratch/store-and-read/   (Dockerfile, app.py)"
      echo "  OpenBao:   http://localhost:8200/ui   (token: devopslings-root)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      L=../../courses/devopslings/module-16/01.store-and-read
      G=$L/greeter.compose.yaml
      S=../../scratch/store-and-read
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
      key=wxp_live_4be1c09f7d2a4e38b6513c8e0f9a27d5
      key_fp=f133ce0d89d2
      probe=wxp_probe_0e5d7c1b9a3f
      probe_fp=b20e8210556a

      fingerprint() {
        curl -fsS --max-time 2 http://127.0.0.1:18160/status 2>/dev/null \
          | sed -n 's/.*"key_fingerprint": *"\([0-9a-f]*\)".*/\1/p' || true
      }
      wait_fingerprint() {
        local fp=""
        for _ in $(seq 40); do
          fp=$(fingerprint)
          [ -n "$fp" ] && break
          sleep 0.5
        done
        printf '%s' "$fp"
      }

      ctr=$(dc ps -q --status running greeter 2>/dev/null || true)
      if [ -z "$ctr" ]; then
        echo "not yet: greeter is not running. From sandboxes/ci-stack:"
        echo "         docker compose up -d --build greeter"
        exit 1
      fi

      # 1. The key has to be in OpenBao, where the app will look for it.
      stored=$(bao kv get -field=key secret/greeter/partner-api 2>/dev/null | tr -d '\r' || true)
      if [ -z "$stored" ]; then
        echo "not yet: OpenBao has nothing at secret/greeter/partner-api (field: key)."
        echo "         Put the partner key there first."
        exit 1
      fi
      if [ "$stored" != "$key" ]; then
        echo "not yet: secret/greeter/partner-api holds a different value from the key"
        echo "         in the Dockerfile. The partner only accepts that one: store it as it is."
        exit 1
      fi

      # 2. No environment: not the image's config, not the container's.
      img=$(docker inspect -f '{{.Image}}' "$ctr")
      if docker image inspect -f '{{json .Config.Env}}' "$img" 2>/dev/null | grep -qF -- "$key"; then
        echo "not yet: the key is still an ENV in greeter's image. Anyone who can pull the"
        echo "         image reads it with: docker image inspect. Remove the ENV line from"
        echo "         scratch/store-and-read/Dockerfile and rebuild."
        exit 1
      fi
      if docker inspect -f '{{json .Config.Env}} {{json .Args}} {{json .Config.Cmd}}' "$ctr" 2>/dev/null \
           | grep -qF -- "$key"; then
        echo "not yet: the key is in greeter's environment, passed in when the container was"
        echo "         created (compose environment: or .env). docker inspect shows it, and so"
        echo "         does /proc/1/environ inside the container. It moved; it is not gone."
        exit 1
      fi

      # 3. No file in the running container, mounts included.
      inside=$(docker exec "$ctr" grep -rlF --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev \
                 -- "$key" / 2>/dev/null | head -1 || true)
      if [ -n "$inside" ]; then
        echo "not yet: $inside inside the greeter container holds the key. A file the app"
        echo "         reads is a file anyone with docker exec, or a backup, also reads."
        exit 1
      fi

      # 4. No image layer. A file deleted by a later layer is still in the
      #    earlier one, and every layer ships with the image.
      hist=$(docker history --no-trunc --format '{{.CreatedBy}}' "$img" 2>/dev/null | grep -F -- "$key" | head -1 || true)
      if [ -n "$hist" ]; then
        echo "not yet: the key is in greeter's build history, which ships with the image:"
        echo "         ${hist:0:100}"
        echo "         Build args and RUN lines are recorded. docker history shows them."
        exit 1
      fi
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      layer_hit=0
      if docker save "$img" -o "$work/img.tar" >/dev/null 2>&1; then
        mkdir "$work/x"
        tar -xf "$work/img.tar" -C "$work/x" 2>/dev/null || true
        while IFS= read -r f; do
          if gzip -t "$f" 2>/dev/null; then
            grep -aqF -- "$key" <(gzip -dc "$f" 2>/dev/null) && { layer_hit=1; break; }
          else
            grep -aqF -- "$key" "$f" && { layer_hit=1; break; }
          fi
        done < <(find "$work/x" -type f)
      fi
      rm -rf "$work"
      if [ "$layer_hit" = 1 ]; then
        echo "not yet: a file in one of greeter's image layers holds the key. Deleting it in"
        echo "         a later layer hides it from the container, not from the image: every"
        echo "         layer is in what you push, and docker save unpacks them."
        exit 1
      fi

      # 5. No file on disk here either.
      outside=$(grep -rlF --exclude-dir=.git -- "$key" . "$S" 2>/dev/null | head -1 || true)
      if [ -n "$outside" ]; then
        echo "not yet: $outside holds the key. Once it is in OpenBao, it should be in no"
        echo "         file on this machine either."
        exit 1
      fi

      # 6. The app must hold the key, or it was simply removed.
      fp=$(wait_fingerprint)
      if [ -z "$fp" ]; then
        echo "not yet: greeter does not answer GET /status with a key fingerprint. It may"
        echo "         have failed to fetch the key. See: docker compose logs greeter"
        exit 1
      fi
      if [ "$fp" != "$key_fp" ]; then
        echo "not yet: greeter holds a different key (fingerprint $fp, the partner key is"
        echo "         $key_fp)."
        exit 1
      fi

      tok=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ctr" \
              | sed -n 's/^BAO_TOKEN=//p' || true)
      policies=$(bao token lookup -format=json "$tok" 2>/dev/null | tr -d ' \r\n' \
                   | sed -n 's/.*[{,]"policies":\[\([^]]*\)\].*/\1/p' | tr -d '"' || true)
      if [ -n "$tok" ] && printf ',%s,' "$policies" | grep -q ',root,'; then
        echo "not yet: greeter logs in to OpenBao with a root token. Whoever can read its"
        echo "         environment can read every secret in OpenBao. Use the token .env gave it."
        exit 1
      fi

      # 7. And it must come from OpenBao at runtime: change the value there,
      #    restart greeter, and it must report the new one. The real key is put
      #    back whatever happens.
      restore() {
        bao kv put secret/greeter/partner-api key="$key" >/dev/null 2>&1 || true
        docker restart "$ctr" >/dev/null 2>&1 || true
        wait_fingerprint >/dev/null
      }
      trap restore EXIT
      bao kv put secret/greeter/partner-api key="$probe" >/dev/null
      docker restart "$ctr" >/dev/null
      fp=$(wait_fingerprint)
      if [ "$fp" != "$probe_fp" ]; then
        echo "not yet: the check changed the value in OpenBao and restarted greeter, and"
        echo "         greeter still reports ${fp:-nothing}. It is not reading the key from"
        echo "         OpenBao when it starts."
        exit 1
      fi

      echo "PASS — greeter fetches the key from OpenBao at startup, and the key is in no"
      echo "       environment, no image layer and no file."
---
