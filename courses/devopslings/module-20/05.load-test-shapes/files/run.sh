#!/usr/bin/env bash
# run.sh SHAPE — run answers/SHAPE.js against quote and save k6's summary as
# answers/SHAPE.json. Run from sandboxes/chaos-stack. Exits with k6's status.
set -uo pipefail
shape=${1:?usage: run.sh ramp|soak|spike|stress|breakpoint}
[ -s "answers/$shape.js" ] || { echo "answers/$shape.js does not exist yet" >&2; exit 2; }
# Tests are run apart, as they would be in a real pipeline: quote sees a quiet
# gap before each one.
sleep 3
docker compose exec -T k6 sh -c "cat > /tmp/$shape.js && k6 run -q --summary-export=/tmp/$shape.json /tmp/$shape.js" < "answers/$shape.js"
rc=$?
docker compose exec -T k6 cat "/tmp/$shape.json" > "answers/$shape.json" 2>/dev/null || rm -f "answers/$shape.json"
exit $rc
