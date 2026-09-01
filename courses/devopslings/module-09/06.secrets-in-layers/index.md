---
kind: lesson
title: "the license key is in the image, and deleting the file did not remove it"
description: |
  The build needs a license key, so it is passed with --build-arg. Anyone who
  pulls the image can read it back out of docker history. Learn what a layer
  keeps, why a later rm does not unkeep it, and how to give a build a secret it
  does not record.
name: secrets-in-layers
slug: secrets-in-layers
createdAt: "2026-08-31"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      docker image rm -f devopslings-licensed >/dev/null 2>&1 || true
      rm -f assets.txt

      cat > unpack.py <<'PY'
      #!/usr/bin/env python3
      """Decrypt the licensed asset. Takes the path to the key file, not the key."""
      import hashlib
      import sys

      key_path, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]

      with open(key_path, "rb") as f:
          key = f.read().strip()
      with open(src) as f:
          data = bytes.fromhex(f.read().strip())

      stream = b""
      counter = 0
      while len(stream) < len(data):
          stream += hashlib.sha256(key + counter.to_bytes(8, "big")).digest()
          counter += 1

      plain = bytes(a ^ b for a, b in zip(data, stream))
      if not plain.startswith(b"LICENSED-ASSET"):
          sys.exit("license key rejected: the asset did not decrypt")

      with open(dst, "wb") as f:
          f.write(plain)
      print(f"unpacked {dst}")
      PY

      cat > app.py <<'PY'
      print(open("/app/assets.txt").read().strip())
      PY

      echo '78323bbfb6e74612ea2e37ebbd62ea55e360316d6858331469560b87a32ee6432ab2' > assets.enc
      echo 'lic_9f4b21c0e7d3_devopslings' > license.key

      # The Dockerfile as CI runs it today. The key arrives as a build arg and is
      # written to a file the build then reads.
      cat > Dockerfile <<'DOCKER'
      FROM python:3.12-slim
      WORKDIR /app
      COPY unpack.py assets.enc app.py ./
      ARG LICENSE_KEY
      RUN echo "$LICENSE_KEY" > /root/.license
      RUN python3 unpack.py /root/.license assets.enc /app/assets.txt
      CMD ["python3", "app.py"]
      DOCKER

      cat > build.sh <<'SH'
      #!/usr/bin/env bash
      # What CI runs. The grader runs this too, so whatever your build needs,
      # put it here.
      set -euo pipefail
      docker build --build-arg LICENSE_KEY="$(cat license.key)" -t devopslings-licensed .
      SH
      chmod +x build.sh

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it leak:"
      echo "  ./build.sh"
      echo "  docker history --no-trunc devopslings-licensed | grep lic_"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      img=devopslings-licensed
      secret='lic_9f4b21c0e7d3_devopslings'
      expected='LICENSED-ASSET-OK sprite-atlas v4'

      for f in Dockerfile build.sh unpack.py assets.enc license.key; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      if [ "$(cat license.key)" != "$secret" ]; then
        echo "not yet: license.key is not the key any more. It is the credential CI"
        echo "holds — the exercise is to stop the image recording it, not to change it."
        exit 1
      fi

      # Decrypting on the laptop and copying the plaintext in would keep the key
      # out of the image by taking the build out of the build.
      if [ -f assets.txt ]; then
        echo "not yet: there is a plaintext assets.txt in $(pwd). Unpacking it here and"
        echo "copying it in dodges the question — the build still has to do the decrypting."
        exit 1
      fi

      docker image rm -f "$img" >/dev/null 2>&1 || true
      if ! out=$(bash build.sh 2>&1); then
        echo "not yet: build.sh failed:"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
        exit 1
      fi

      if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "not yet: build.sh exited 0 but built no image tagged $img — keep the tag,"
        echo "it is what the rest of the pipeline pulls."
        exit 1
      fi

      got=$(docker run --rm "$img" 2>&1 || true)
      if [ "$got" != "$expected" ]; then
        echo "not yet: the image does not print the licensed asset. It said:"
        printf '%s\n' "$got" | tail -10 | sed 's/^/    /'
        echo "The key still has to reach the build — just not into the image."
        exit 1
      fi

      # Two separate hiding places. History carries the instructions and the build
      # args they ran with; the layers carry the bytes.
      # Matched in the shell rather than through `grep -q`: under pipefail an
      # early-exiting grep SIGPIPEs docker history, and the pipeline reports
      # failure on the run where the secret was found.
      hist=$(docker history --no-trunc "$img" 2>/dev/null || true)
      case "$hist" in *"$secret"*)
        echo "not yet: the key is in docker history, which ships with the image:"
        printf '%s\n' "$hist" | grep "$secret" | head -2 | sed 's/^.*ago  *//' | cut -c1-120 | sed 's/^/    /' || true
        echo "A build arg is recorded against the instruction that used it, and ENV is"
        echo "recorded in the image config. Neither is a way to pass a secret."
        exit 1
        ;;
      esac

      hits=$(docker save "$img" 2>/dev/null | grep -a -c "$secret" || true)
      if [ "${hits:-0}" != "0" ]; then
        echo "not yet: docker history is clean and the key is still in the image —"
        echo "$hits occurrence(s) in the saved layers."
        echo "A layer is a snapshot of what changed. Removing the file in a later"
        echo "layer records the deletion; it does not edit the layer that holds it."
        exit 1
      fi

      echo "PASS — the build still unpacks the asset, and the key is in neither the"
      echo "history nor any layer of $img."
---
