---
kind: lesson
title: "The support index stopped taking tickets at 02:14"
description: |
  Every support ticket goes into an OpenSearch index, and since the night
  shift most of them have been refused. The error says the index has
  too many fields. Each customer's custom fields became fields of the index,
  and there are more customers than the index will hold. Give the index a
  mapping that cannot grow like that, keep custom fields searchable, and
  lose no ticket on the way.
name: mapping-explosion
slug: mapping-explosion
createdAt: "2026-11-15"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      obs-reset >/dev/null
      O=http://opensearch:9200
      for i in $(seq 1 180); do
        curl -sf "$O/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1 && break
        [ "$i" = 180 ] && { echo "OpenSearch did not start in 3 minutes"; exit 1; }
        sleep 1
      done
      curl -sf -XDELETE "$O/support*?expand_wildcards=all" >/dev/null || true
      curl -sf -XPUT "$O/support-v1" -H 'Content-Type: application/json' -d '{
        "settings": {"number_of_shards": 1, "number_of_replicas": 0},
        "aliases": {"support": {"is_write_index": true}}
      }' >/dev/null
      rm -rf /obs/opensearch && mkdir -p /obs/opensearch
      python3 - <<'PY'
      import json, random
      r = random.Random(1906)
      VALUES = ["gold", "silver", "bronze", "emea", "apac", "amer", "renewal", "trial", "yes", "no"]
      tenants = {f"t{n:03d}": [f"cf_{r.randrange(3600000, 3699999)}" for _ in range(r.randint(3, 6))]
                 for n in range(400)}
      names = sorted(tenants)
      SUBJECTS = ["cannot log in", "refund not received", "invoice is wrong", "export times out",
                  "SSO certificate expired", "seat count does not match", "webhook stopped firing"]
      with open("/obs/opensearch/tickets.ndjson", "w") as f:
          for i in range(1, 1201):
              t = r.choice(names)
              f.write(json.dumps({
                  "ticket_id": f"T-{i:05d}",
                  "ts": f"2026-11-15T{(i * 2) // 100 % 24:02d}:{i % 60:02d}:{(i * 7) % 60:02d}Z",
                  "tenant": t,
                  "status": r.choice(["open", "open", "pending", "solved"]),
                  "priority": r.choice(["p1", "p2", "p3", "p3"]),
                  "subject": r.choice(SUBJECTS),
                  "custom": {k: (r.randrange(1, 500) if k.endswith(("1", "2")) else r.choice(VALUES))
                             for k in r.sample(tenants[t], r.randint(2, len(tenants[t])))},
              }) + "\n")
      PY
      ticket-ship /obs/opensearch/tickets.ndjson >/obs/opensearch/last-run.txt || true
      curl -sf -XPOST "$O/support/_refresh" >/dev/null
      chmod -R a+rwX /obs/opensearch
      echo "scenario ready: last night's 1200 tickets went to the alias 'support' (index support-v1)."
      sed 's/^/  /' /obs/opensearch/last-run.txt
      echo "OpenSearch is at http://opensearch:9200 (localhost:19200 from your browser)."

  verify_done:
    timeout_seconds: 180
    run: |
      python3 - <<'PY'
      import json, sys, urllib.error, urllib.request, uuid

      OS = "http://opensearch:9200"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def call(method, path, body=None, ndjson=False):
          data = None if body is None else (body if ndjson else json.dumps(body)).encode()
          req = urllib.request.Request(f"{OS}{path}", data=data, method=method, headers={
              "Content-Type": "application/x-ndjson" if ndjson else "application/json"})
          try:
              with urllib.request.urlopen(req, timeout=60) as r:
                  return r.status, json.load(r)
          except urllib.error.HTTPError as e:
              try:
                  return e.code, json.load(e)
              except ValueError:
                  return e.code, {}
          except OSError as e:
              no(f"OpenSearch does not answer on {OS} ({getattr(e, 'reason', e)}).")

      def fields(props):
          n = 0
          for spec in props.values():
              n += 1 + len(spec.get("fields", {}))
              n += fields(spec.get("properties", {}))
          return n

      code, aliases = call("GET", "/_alias/support")
      if code != 200 or not aliases:
          no("there is no alias named support. ticket-ship writes through it, and support's",
             "searches read through it.")
      writers = [i for i, a in aliases.items() if a["aliases"]["support"].get("is_write_index")]
      if len(aliases) > 1 and len(writers) != 1:
          no(f"the alias support covers {', '.join(sorted(aliases))} and none of them is its write",
             "index, so OpenSearch refuses every write through it. Mark one with is_write_index.")
      idx = writers[0] if writers else next(iter(aliases))
      mapping = lambda: call("GET", f"/{idx}/_mapping")[1][idx]["mappings"]
      m = mapping()
      before = fields(m.get("properties", {}))
      dyn = str(m.get("dynamic", "true")).lower()
      custom = m.get("properties", {}).get("custom", {})

      # New customers arrive with custom fields nobody has seen.
      run = uuid.uuid4().hex[:8]
      probes = [{"ticket_id": f"probe-{run}-{i}", "ts": "2026-11-15T09:00:00Z", "tenant": f"new-{run}-{i}",
                 "status": "open", "priority": "p3", "subject": "probe from the check",
                 "custom": {f"cf_9{run[:3]}{i:02d}{k:03d}": "gold" for k in range(30)}} for i in range(20)]
      body = "".join(json.dumps({"index": {"_id": p["ticket_id"]}}) + "\n" + json.dumps(p) + "\n" for p in probes)
      code, res = call("POST", "/support/_bulk?refresh=true", body, ndjson=True)
      errs = [it["index"]["error"] for it in res.get("items", []) if "error" in it["index"]] if code == 200 \
          else [res.get("error", {})]
      def cleanup():
          call("POST", "/support/_delete_by_query?refresh=true",
               {"query": {"prefix": {"ticket_id": f"probe-{run}"}}})
      if errs:
          cleanup()
          e = errs[0] if isinstance(errs[0], dict) else {"reason": str(errs[0])}
          if e.get("type") == "strict_dynamic_mapping_exception":
              no(f"{len(errs)} of 20 new tickets were refused by {idx}:", f"  {e.get('reason', '')[:200]}",
                 "dynamic: strict turns every new custom field into a rejected ticket, which is the",
                 "same data loss with a different error.")
          no(f"{len(errs)} of 20 new tickets, from customers with custom fields not seen before, were",
             f"refused writing through support (to {idx}):", f"  {e.get('type', '')}: {e.get('reason', '')[:200]}")
      after = fields(mapping().get("properties", {}))
      if after > before + 5:
          cleanup()
          no(f"20 new tickets with 600 custom fields nobody had seen grew {idx}'s mapping",
             f"from {before} to {after} fields. Each new key is still a field of the index, so the next",
             "customers fill it again whatever the limit is set to.")
      if dyn not in ("false", "strict"):
          cleanup()
          no(f"{idx}'s mapping still adds any new top-level field it is sent (dynamic: {dyn}).",
             "The custom fields are bounded; the next client that puts its own fields at the top",
             "level grows the index again. Map the fields tickets have, and say what happens to",
             "the rest.")

      # Support finds a ticket by a custom field.
      key = next(iter(probes[7]["custom"]))
      _, hits = call("POST", "/support/_search", {"query": {"match": {f"custom.{key}": "gold"}}})
      found = {h["_id"] for h in hits.get("hits", {}).get("hits", [])}
      if probes[7]["ticket_id"] not in found:
          cleanup()
          kind = custom.get("type") or ("object, enabled: false" if custom.get("enabled") is False else
                                        f"object, dynamic: {custom.get('dynamic', dyn)}")
          no(f"a search for custom.{key}:gold does not find the ticket that has it.",
             f"In {idx} the custom fields are mapped as {kind}: kept in _source and",
             "not indexed, so support can no longer search by them. They need a type that indexes",
             "every key and value without making each key a field.")
      cleanup()

      # Every ticket from last night, exactly once.
      want = [json.loads(l)["ticket_id"] for l in open("/obs/opensearch/tickets.ndjson")]
      _, res = call("POST", "/support/_search", {"size": 5000, "_source": False, "query": {"ids": {"values": want}}})
      hits = res.get("hits", {}).get("hits", [])
      got = {h["_id"] for h in hits}
      missing = [t for t in want if t not in got]
      if len(hits) > len(got):
          where = sorted({h["_index"] for h in hits})
          no(f"support returns {len(hits) - len(got)} tickets twice: the alias covers {', '.join(where)},",
             "and the same tickets are in more than one of them. Every search counts them twice.")
      if missing:
          _, res = call("POST", "/_all/_search", {"size": 5000, "_source": False, "query": {"ids": {"values": missing}}})
          elsewhere = {h["_id"]: h["_index"] for h in res.get("hits", {}).get("hits", [])}
          try:
              dead = {json.loads(l)["ticket_id"] for l in open("/obs/opensearch/dead-letter.ndjson") if l.strip()}
          except OSError:
              dead = set()
          if elsewhere:
              where = sorted(set(elsewhere.values()))
              no(f"{len(missing)} of last night's {len(want)} tickets are not in what support covers.",
                 f"{len(elsewhere)} of them, such as {next(iter(elsewhere))}, are in {', '.join(where)},",
                 "which the alias no longer includes.")
          n = len(dead & set(missing))
          no(f"{len(missing)} of last night's {len(want)} tickets are in no index, such as {missing[0]}.",
             ("Every one of them" if n == len(missing) else f"{n} of them") +
             " is in /obs/opensearch/dead-letter.ndjson: refused, and not shipped since.")
      print(f"PASS — {idx} took 20 new customers' tickets with 600 unseen custom fields without")
      print(f"growing ({after} fields), finds them by custom field, and holds all {len(want)} tickets once.")
      PY
---
