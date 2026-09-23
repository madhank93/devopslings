#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three separate things: stop Redis choosing victims from keys that are not
# cache, give the cache the mark that makes it the only thing it can choose,
# and let the queue survive the process.
set -euo pipefail

# Only keys that declare themselves disposable may be evicted. The queue never
# will, so it stops being a candidate.
redis-cli CONFIG SET maxmemory-policy volatile-lru >/dev/null

# The queue is the only copy of the work it holds.
redis-cli CONFIG SET appendonly yes >/dev/null

# Both of those are running config until they are written back to the file the
# server reads at startup.
redis-cli CONFIG REWRITE >/dev/null

# Last night's pages were written without a TTL, so under volatile-lru they are
# un-evictable dead weight sitting against the ceiling. They are a cache: drop
# them and let the next warm write them properly.
redis-cli --scan --pattern 'cache:*' | xargs -r redis-cli UNLINK >/dev/null

# And the writer has to mark what it writes, or the policy has nothing to take
# and the ceiling turns into refused writes.
cat > /work/app/cache-warm.sh <<'SH'
#!/usr/bin/env bash
# Nightly cache warm: render the top product pages into Redis so the morning is
# not spent rebuilding them out of Postgres.
#
# Every page carries a TTL. That is not housekeeping — it is what tells Redis
# these keys are a copy of something it can afford to lose, and under a
# volatile-* policy it is the only reason the ceiling is survivable.
set -euo pipefail
pages=${1:-3000}
ttl=${2:-3600}
body="$(head -c 16384 /dev/zero | tr '\0' x)"
{
  for i in $(seq 1 "$pages"); do
    echo "SET cache:page:$i $body EX $ttl"
  done
} | redis-cli --pipe >/dev/null
echo "warmed $pages pages — $(redis-cli DBSIZE) keys, $(redis-cli INFO memory | tr -d '\r' | sed -n 's/^used_memory_human://p') used"
SH
chmod +x /work/app/cache-warm.sh

install -d /work/answers
cat > /work/answers/redis-eviction.md <<'MD'
# The queue that lost jobs overnight

# The maxmemory-policy Redis was running under while the jobs were going
# missing — the name redis-cli gives it.
evicting-policy: allkeys-lru

# Under the policy that should be running instead, what has to be true of
# a key before Redis is allowed to evict it?
what-makes-a-key-evictable: it has to carry a TTL — volatile-lru only considers keys with an expiry set, so a key without one is never a candidate

# maxmemory was raised once already and the losses came back. The cache
# grows for as long as there are pages to render. One line: why is a
# bigger ceiling not the fix?
why-not-more-memory: the cache grows without bound so it reaches any ceiling eventually, and raising it only delays the next eviction rather than changing which keys get chosen
MD

echo "volatile-lru with TTLs on the cache, AOF on, and both written back to the config file"
