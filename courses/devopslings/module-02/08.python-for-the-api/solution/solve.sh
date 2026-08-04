#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/fetch-records <<'PY'
#!/usr/bin/env python3
"""Pull the billing export and write one record id per line.

Three things the naive version did not do, and every paginated API needs all
three: follow the pages, retry what is retryable, and obey what the server
tells you about waiting.
"""
import json
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8099/records"
MAX_ATTEMPTS = 6


def get_page(page):
    """Fetch one page, retrying transient failures.

    429 and 503 mean 'not now', not 'never' — they are worth retrying. A 4xx
    other than 429 means the request itself is wrong, and retrying an invalid
    request just makes the same mistake repeatedly.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(f"{BASE}?page={page}", timeout=10) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                # The server said exactly how long to wait. Use its number, not
                # ours — our backoff has no idea what the server's window is.
                delay = float(e.headers.get("Retry-After", "1"))
            elif e.code == 503:
                # Nothing told us how long, so back off exponentially rather
                # than hammering: 0.5s, 1s, 2s, ...
                delay = 0.5 * (2 ** (attempt - 1))
            else:
                raise
            if attempt == MAX_ATTEMPTS:
                raise
            time.sleep(delay)
    raise RuntimeError(f"page {page}: exhausted retries")


ids = []
page = 1
while page is not None:
    data = get_page(page)
    ids.extend(item["id"] for item in data["items"])
    # Follow what the response says rather than guessing at a page count.
    page = data.get("next_page")

# Sort, and de-duplicate defensively: a retry that succeeded after a response
# was partially processed would otherwise double up.
ids = sorted(set(ids))

with open("/srv/api/records.txt", "w") as f:
    f.write("\n".join(ids) + "\n")

print(f"fetch-records: wrote {len(ids)} records")
PY
chmod 0755 /usr/local/bin/fetch-records
