---
kind: lesson
title: "healthy, and dropping every real request"
description: |
  quote-api passes every health check and resets every real request. The image
  is distroless: no shell, no ps, no ss, nothing to exec into. Rebuilding it
  with a shell changes the thing being debugged. Bring the tools to the
  container instead, find the cause from inside its namespaces, and fix it
  without touching the image.
name: debug-a-distroless-container
slug: debug-a-distroless-container
createdAt: "2026-11-22"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      docker rm -f quote-api >/dev/null 2>&1 || true
      docker volume rm -f quote-api-config >/dev/null 2>&1 || true
      rm -rf build answers
      mkdir -p build answers

      cat > build/app.py <<'PY'
      import configparser, http.server, json, threading

      cfg = configparser.ConfigParser()
      cfg.read("/etc/quote-api/app.ini")

      def addr(section):
          host, _, port = cfg[section]["listen"].rpartition(":")
          return (host, int(port))

      class Health(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(200 if self.path == "/healthz" else 404)
              self.end_headers()
              self.wfile.write(b"ok\n")
          def log_message(self, *a):
              pass

      class Api(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              if not self.path.startswith("/quote"):
                  self.send_response(404); self.end_headers(); return
              body = json.dumps({"sku": "SKU-0042", "cents": 1299}).encode()
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *a):
              pass

      for name, handler in (("health", Health), ("api", Api)):
          srv = http.server.ThreadingHTTPServer(addr(name), handler)
          threading.Thread(target=srv.serve_forever, daemon=True).start()
          print(f"{name} listener ready", flush=True)
      threading.Event().wait()
      PY
      cat > build/Dockerfile <<'DF'
      FROM gcr.io/distroless/python3-debian12:nonroot
      COPY app.py /app/app.py
      CMD ["/app/app.py"]
      DF
      docker build -q -t devopslings/quote-api:1.4.2 build >/dev/null

      # The config lives in a volume, as it does on the real hosts: it is
      # managed by the deploy tool, not baked into the image.
      docker volume create quote-api-config >/dev/null
      docker run --rm -i -v quote-api-config:/c busybox:1.37 sh -c 'cat > /c/app.ini' <<'INI'
      [health]
      listen = 0.0.0.0:8081

      [api]
      listen = localhost:8080
      INI

      docker run -d --name quote-api \
        -p 127.0.0.1:18430:8080 -p 127.0.0.1:18431:8081 \
        -v quote-api-config:/etc/quote-api:ro \
        devopslings/quote-api:1.4.2 >/dev/null
      docker inspect -f '{{.Image}}' quote-api > build/image-id

      for _ in $(seq 1 40); do
        curl -fsS -m 2 http://127.0.0.1:18431/healthz >/dev/null 2>&1 && break
        sleep 0.5
      done
      curl -fsS -m 2 http://127.0.0.1:18431/healthz >/dev/null

      echo "scenario ready — quote-api: health on 127.0.0.1:18431, traffic on 127.0.0.1:18430."
      echo "  curl http://127.0.0.1:18431/healthz"
      echo "  curl http://127.0.0.1:18430/quote"
      echo "Write your findings to $(pwd)/answers/distroless.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=answers/distroless.txt
      v=$({ grep -E '^listening=' "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "')
      if [ -z "$v" ]; then
        echo "not yet: $ans needs listening=<address:port>: where the API socket in the quote-api"
        echo "         container is actually listening, read from inside its network namespace."
        exit 1
      fi
      case "$v" in
        127.0.0.1:8080) ;;
        localhost:8080)
          echo "not yet: listening=$v is what the config asks for. The socket table shows what the"
          echo "         name resolved to; netstat -ltn from a container on the same network namespace"
          echo "         prints the address itself."
          exit 1 ;;
        *:18430|*:18431)
          echo "not yet: listening=$v is the published port on your host. Docker forwards it to a port"
          echo "         inside the container; the answer is where that one listens."
          exit 1 ;;
        *)
          echo "not yet: listening=$v. Run a tools image with --network=container:quote-api and list"
          echo "         the listening TCP sockets; one of the two is not on every address."
          exit 1 ;;
      esac

      want=$(cat build/image-id 2>/dev/null || true)
      got=$(docker inspect -f '{{.Image}}' quote-api 2>/dev/null || true)
      if [ -z "$got" ]; then
        echo "not yet: there is no quote-api container. Restart it from devopslings/quote-api:1.4.2"
        echo "         with the same ports and config volume; reset the lesson if the image is gone."
        exit 1
      fi
      if [ "$got" != "$want" ]; then
        echo "not yet: quote-api runs image $got, not the one it was deployed with ($want)."
        echo "         The image is what production runs; the fix has to be in its config."
        exit 1
      fi
      if [ "$(docker inspect -f '{{.State.Running}}' quote-api)" != true ]; then
        echo "not yet: quote-api is not running. docker logs quote-api says why."
        exit 1
      fi
      if ! curl -fsS -m 3 http://127.0.0.1:18431/healthz >/dev/null 2>&1; then
        echo "not yet: the health check on 127.0.0.1:18431 no longer answers."
        exit 1
      fi
      body=$(curl -fsS -m 3 http://127.0.0.1:18430/quote 2>/dev/null || true)
      if ! grep -Eq '"cents": *1299([^0-9]|$)' <<<"$body"; then
        echo "not yet: http://127.0.0.1:18430/quote still fails. Docker delivers published traffic to the"
        echo "         container's eth0 address, and a socket bound to loopback never sees it."
        echo "         Change the listen address in the config volume and restart the container."
        exit 1
      fi
      echo "PASS — the API listened on $v, where Docker's forwarded traffic cannot reach it;"
      echo "       it now serves real requests from the same image, $want."
---
