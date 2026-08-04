---
kind: lesson
title: "the report that has been missing 40% of the records all year"
description: |
  fetch-records pulls the billing export and writes it to a file. The file has
  50 rows. There are 437 records. Nothing errors, nothing retries, and the API
  has been telling the client about the other eight pages the whole time.
name: python-for-the-api
slug: python-for-the-api
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /srv/api /var/lib/devopslings /root/answers
      rm -f /srv/api/records.txt

      cat > /usr/local/bin/records-api <<'PY'
      #!/usr/bin/env python3
      """A small billing export API. Deterministic: the same request sequence
      always produces the same failures, so a fix is a fix and not luck."""
      import http.server, json, time, urllib.parse

      TOTAL, PER_PAGE = 437, 50
      PAGES = (TOTAL + PER_PAGE - 1) // PER_PAGE

      STATE = {
          "hits": {},          # page -> how many times it has been requested
          "last_request": 0.0, # for rate-limit accounting
          "violations": 0,     # requests that ignored Retry-After
          "retry_after_until": 0.0,
      }

      # A fixed schedule of failures, keyed on (page, attempt-number). Every
      # client meets exactly the same ones.
      FAILURES = {
          (2, 1): 503,   # transient
          (5, 1): 503,
          (5, 2): 503,   # twice, so one blind retry is not enough
          (7, 1): 429,   # rate limited, with Retry-After
      }

      class H(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def _send(self, code, payload, headers=None):
              body = json.dumps(payload).encode()
              self.send_response(code)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              for k, v in (headers or {}).items():
                  self.send_header(k, v)
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              u = urllib.parse.urlparse(self.path)
              q = urllib.parse.parse_qs(u.query)

              if u.path == "/stats":
                  return self._send(200, {"violations": STATE["violations"]})

              if u.path != "/records":
                  return self._send(404, {"error": "not found"})

              now = time.monotonic()
              # If we told the client to wait, and it did not, record it.
              if now < STATE["retry_after_until"]:
                  STATE["violations"] += 1

              try:
                  page = int(q.get("page", ["1"])[0])
              except ValueError:
                  return self._send(400, {"error": "page must be an integer"})
              if page < 1 or page > PAGES:
                  return self._send(404, {"error": f"no such page: {page}"})

              STATE["hits"][page] = STATE["hits"].get(page, 0) + 1
              attempt = STATE["hits"][page]

              code = FAILURES.get((page, attempt))
              if code == 503:
                  return self._send(503, {"error": "upstream busy, try again"})
              if code == 429:
                  STATE["retry_after_until"] = now + 2.0
                  return self._send(429, {"error": "rate limited"},
                                    {"Retry-After": "2"})

              start = (page - 1) * PER_PAGE
              items = [{"id": f"REC-{i:05d}", "amount": (i * 37) % 9973}
                       for i in range(start + 1, min(start + PER_PAGE, TOTAL) + 1)]
              return self._send(200, {
                  "page": page,
                  "per_page": PER_PAGE,
                  "total": TOTAL,
                  "next_page": page + 1 if page < PAGES else None,
                  "items": items,
              })

          def log_message(self, *a):
              pass

      http.server.HTTPServer(("127.0.0.1", 8099), H).serve_forever()
      PY
      chmod 0755 /usr/local/bin/records-api

      cat > /etc/systemd/system/records-api.service <<'UNIT'
      [Unit]
      Description=Billing export API

      [Service]
      ExecStart=/usr/local/bin/records-api
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat > /usr/local/bin/fetch-records <<'PY'
      #!/usr/bin/env python3
      """Pull the billing export and write one id per line."""
      import json, urllib.request

      with urllib.request.urlopen("http://127.0.0.1:8099/records?page=1", timeout=10) as r:
          data = json.load(r)

      with open("/srv/api/records.txt", "w") as f:
          for item in data["items"]:
              f.write(item["id"] + "\n")

      print(f"fetch-records: wrote {len(data['items'])} records")
      PY
      chmod 0755 /usr/local/bin/fetch-records

      systemctl daemon-reload
      systemctl enable records-api.service >/dev/null 2>&1 || true
      systemctl restart records-api.service >/dev/null 2>&1 || true
      sleep 2

      echo 437 > /var/lib/devopslings/api.total

      cat > /root/questions.txt <<'Q'
      /usr/local/bin/fetch-records writes /srv/api/records.txt, one record id per
      line. There are 437 records. It writes 50.

      Fix it so that it writes every record exactly once, sorted, and:

        - the API paginates. The response tells you how to continue.
        - some requests fail with 503. They succeed if you try again; one page
          fails twice, so a single blind retry is not enough. Back off between
          attempts.
        - one request returns 429 with a Retry-After header. Honour it. The
          server counts requests that arrive before that deadline, and the check
          requires that count to be zero.

      Restarting records-api.service resets its failure schedule, which is fine —
      the schedule is the same every time.
      Q

      echo "scenario ready — fetch-records writes $( /usr/local/bin/fetch-records >/dev/null 2>&1; wc -l < /srv/api/records.txt 2>/dev/null || echo 0 ) of 437 records"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want_total=$(cat /var/lib/devopslings/api.total)

      if [ ! -x /usr/local/bin/fetch-records ]; then
        echo "not yet: /usr/local/bin/fetch-records is missing or not executable"
        exit 1
      fi

      # Fresh server, so the failure schedule starts from the beginning.
      systemctl restart records-api.service >/dev/null 2>&1 || true
      for _ in $(seq 1 40); do
        curl -sf http://127.0.0.1:8099/stats >/dev/null 2>&1 && break
        sleep 0.25
      done

      rm -f /srv/api/records.txt
      set +e
      out=$(/usr/local/bin/fetch-records 2>&1); rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "not yet: fetch-records exited $rc"
        printf '%s\n' "$out" | tail -6 | sed 's/^/         /'
        echo "         a 503 on one page is not a reason to abandon the export — the API"
        echo "         says to try again."
        exit 1
      fi

      if [ ! -s /srv/api/records.txt ]; then
        echo "not yet: /srv/api/records.txt is missing or empty"
        exit 1
      fi

      lines=$(wc -l < /srv/api/records.txt)
      uniq_n=$(sort -u /srv/api/records.txt | wc -l)

      if [ "$uniq_n" -ne "$want_total" ]; then
        echo "not yet: got $uniq_n distinct records, expected $want_total"
        if [ "$uniq_n" -eq 50 ]; then
          echo "         that is exactly one page. The response carries next_page — follow"
          echo "         it until it is null."
        elif [ "$uniq_n" -lt "$want_total" ]; then
          missing=$(( want_total - uniq_n ))
          echo "         $missing missing. Pages 2 and 5 fail with 503 on their first"
          echo "         attempt, and page 5 fails again on its second. A client that"
          echo "         gives up on a page, or retries it only once, loses it silently."
        fi
        exit 1
      fi

      if [ "$lines" -ne "$uniq_n" ]; then
        echo "not yet: $lines lines but only $uniq_n distinct ids — some are written twice"
        echo "         a retry must not re-append a page that already succeeded."
        exit 1
      fi

      if ! sort -c /srv/api/records.txt 2>/dev/null; then
        echo "not yet: /srv/api/records.txt is not sorted"
        exit 1
      fi

      first=$(head -1 /srv/api/records.txt)
      last=$(tail -1 /srv/api/records.txt)
      if [ "$first" != "REC-00001" ] || [ "$last" != "REC-00437" ]; then
        echo "not yet: expected REC-00001 through REC-00437, got $first through $last"
        exit 1
      fi

      violations=$(curl -sf http://127.0.0.1:8099/stats | sed -n 's/.*"violations": *\([0-9]*\).*/\1/p')
      if [ "${violations:-1}" -ne 0 ]; then
        echo "not yet: the server recorded $violations request(s) that arrived before the"
        echo "         Retry-After deadline it gave you."
        echo "         A 429 is the server telling you exactly how long to wait. Retrying"
        echo "         immediately — or on your own backoff schedule — ignores the one"
        echo "         piece of information it sent."
        exit 1
      fi

      echo "PASS — all $want_total records, each once, in order, with 0 rate-limit violations."
---
