#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The standard pins a semantic-conventions release and its attribute names;
# platform owns obs-lib, which sets them; and the gate reads standard.yaml, so
# the rule and its enforcement cannot drift apart.
set -euo pipefail
cat > /obs/standard/standard.yaml <<'YML'
semconv_version: "1.30.0"
resource_attributes:
  - service.name
  - service.version
  - deployment.environment.name
server_span_attributes:
  - http.request.method
  - http.route
  - http.response.status_code
shared_instrumentation_owner: platform
YML
cat > /obs/standard/gate <<'PY'
#!/usr/bin/env python3
"""gate EXPORT.json — exit 0 when an OTLP/JSON export meets standard.yaml;
otherwise list each missing attribute and exit 1."""
import json, sys
import yaml

std = yaml.safe_load(open("/obs/standard/standard.yaml"))
SERVER = (2, "SPAN_KIND_SERVER")

def keys(attributes):
    return {a["key"] for a in attributes or []}

missing = set()
for rs in json.load(open(sys.argv[1])).get("resourceSpans", []):
    have = keys(rs.get("resource", {}).get("attributes"))
    missing |= {f"resource: {k}" for k in std["resource_attributes"] if k not in have}
    for ss in rs.get("scopeSpans", []):
        for s in ss.get("spans", []):
            if s.get("kind") in SERVER:
                have = keys(s.get("attributes"))
                missing |= {f"SERVER span '{s.get('name')}': {k}" for k in std["server_span_attributes"] if k not in have}
if missing:
    print("instrumentation standard: missing")
    print("\n".join(f"  {m}" for m in sorted(missing)))
    sys.exit(1)
print("instrumentation standard: ok")
PY
chmod +x /obs/standard/gate
