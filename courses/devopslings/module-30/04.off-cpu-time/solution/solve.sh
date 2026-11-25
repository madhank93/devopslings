#!/bin/sh
set -e
# Fetch into a local buffer outside the lock; hold the lock only for the copy.
python3 - <<'PY'
p = "/opt/quotes/quotes.c"
s = open(p).read()
old = """        pthread_mutex_lock(&rates_lock);
        fetch_rates(rates, sizeof rates);
        version++;
        pthread_mutex_unlock(&rates_lock);"""
new = """        char fresh[sizeof rates];
        if (fetch_rates(fresh, sizeof fresh) == 0) {
            pthread_mutex_lock(&rates_lock);
            memcpy(rates, fresh, sizeof rates);
            version++;
            pthread_mutex_unlock(&rates_lock);
        }"""
if old in s:
    open(p, "w").write(s.replace(old, new))
elif new not in s:
    raise SystemExit("refresh loop not found in quotes.c")
PY
make -s -C /opt/quotes
systemctl restart quotes.service
cat > /root/answers/offcpu.md <<'A'
waits-on: rates_lock (pthread mutex) in handle_quote, held by the rates-refresh thread across fetch_rates' 900 ms feed round trip
A
