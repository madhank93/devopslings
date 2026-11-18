#!/usr/bin/env bash
# profile.sh QUOTE_PY [SECONDS] [bench] — benchmark QUOTE_PY inside the checkout
# container (default 5 seconds) while sampling its stack. Writes the samples to
# answers/quote.folded and prints them as a text flame graph. With `bench`, it
# only prints the rate. Run from sandboxes/chaos-stack.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
src=$1; secs=${2:-5}
dir=/srv/flame-graph
docker compose exec -T checkout sh -c "rm -rf $dir && mkdir -p $dir"
for f in orders.py bench.py flame.py check.py quote.py; do
  docker compose cp "$lesson/files/$f" "checkout:$dir/$( [ $f = quote.py ] && echo original.py || echo $f)" >/dev/null 2>&1
done
docker compose cp "$src" "checkout:$dir/quote.py" >/dev/null 2>&1
if [ "${3:-}" = bench ]; then
  docker compose exec -T -w "$dir" checkout timeout 60 python3 bench.py quote.py "$secs"
  exit
fi
docker compose exec -T -w "$dir" checkout timeout 60 python3 bench.py quote.py "$secs" quote.folded
mkdir -p answers
docker compose exec -T checkout cat "$dir/quote.folded" > answers/quote.folded
docker compose exec -T -w "$dir" checkout python3 flame.py quote.folded 2
