#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Drop what cannot be parsed before the transform sees it, then split request
# into the three schema attributes with a typed status code and remove the
# source field. error_mode: ignore is the second line of defence: a record
# that still fails a statement is logged and passed on, not the whole batch.
set -euo pipefail
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["processors"] = {
    "filter/malformed": {
        "error_mode": "ignore",
        "logs": {"log_record": [
            'not IsString(attributes["request"]) or not IsMatch(attributes["request"], "^[A-Z]+ \\\\S+ \\\\d{3}$")',
        ]},
    },
    "transform/request": {
        "error_mode": "ignore",
        "log_statements": [{"context": "log", "statements": [
            'merge_maps(attributes, ExtractPatterns(attributes["request"], "^(?P<method>[A-Z]+) (?P<path>\\\\S+) (?P<status>\\\\d{3})$"), "upsert")',
            'set(attributes["http.request.method"], attributes["method"])',
            'set(attributes["url.path"], attributes["path"])',
            'set(attributes["http.response.status_code"], Int(attributes["status"]))',
            'delete_matching_keys(attributes, "^(method|path|status|request)$")',
        ]}],
    },
}
c["service"]["pipelines"]["logs"]["processors"] = ["filter/malformed", "transform/request"]
yaml.safe_dump(c, open(p, "w"), sort_keys=False, width=200)
PY
