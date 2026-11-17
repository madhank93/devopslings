#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Walk every string in the event, however deep, and replace what is shaped
# like an address: a local part, an @, and a domain ending in a dot and
# letters. "ord-1@eu-west-1" and "release@4.2.1" have no such domain.
set -euo pipefail
cat > /obs/vector/redact.vrl <<'VRL'
# Runs on every support log event before it leaves the host.
# Replace each customer email address with [REDACTED], wherever it is.
. = map_values(., recursive: true) -> |value| {
  if is_string(value) {
    replace(string!(value), r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', "[REDACTED]")
  } else {
    value
  }
}
VRL
