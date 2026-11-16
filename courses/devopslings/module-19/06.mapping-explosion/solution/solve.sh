#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A new index whose mapping names every top-level field and maps the custom
# fields as one flat_object, which indexes every key and value without adding
# a field per key. Copy the tickets that made it, move the alias in one
# step, and replay the ones that were refused.
set -euo pipefail
O=http://opensearch:9200
j() { curl -sf -H 'Content-Type: application/json' "$@"; }
j -XPUT "$O/support-v2" -d '{
  "settings": {"number_of_shards": 1, "number_of_replicas": 0},
  "mappings": {
    "dynamic": false,
    "properties": {
      "ticket_id": {"type": "keyword"},
      "ts":        {"type": "date"},
      "tenant":    {"type": "keyword"},
      "status":    {"type": "keyword"},
      "priority":  {"type": "keyword"},
      "subject":   {"type": "text"},
      "custom":    {"type": "flat_object"}
    }
  }
}' >/dev/null
j -XPOST "$O/_reindex?refresh=true" -d '{"source": {"index": "support-v1"}, "dest": {"index": "support-v2"}}' >/dev/null
j -XPOST "$O/_aliases" -d '{"actions": [
  {"remove": {"index": "support-v1", "alias": "support"}},
  {"add": {"index": "support-v2", "alias": "support", "is_write_index": true}}
]}' >/dev/null
ticket-ship /obs/opensearch/dead-letter.ndjson
curl -sf -XPOST "$O/support/_refresh" >/dev/null
