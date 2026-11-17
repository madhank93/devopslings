---
kind: lesson
title: "Customer emails are in the support logs, and the first redaction ate the order ids"
description: |
  Support's logs carry customer email addresses in five different places, and
  they are shipped to a store half the company can read. Someone wrote a VRL
  regex to scrub them. It also scrubs the order references, which is how
  support finds anything. Redact every email and nothing else, field by
  field.
name: vrl-redact-pii
slug: vrl-redact-pii
createdAt: "2026-11-14"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 60
    run: |
      obs-reset >/dev/null
      cat > /obs/vector/redact.vrl <<'VRL'
      # Runs on every support log event before it leaves the host.
      # Replace each customer email address with [REDACTED].
      .message = replace(string!(.message), r'\S+@\S+', "[REDACTED]")
      VRL
      support-logs 40 > /obs/vector/support.ndjson
      echo "scenario ready: /obs/vector/redact.vrl is the redaction; /obs/vector/support.ndjson is"
      echo "a sample of the events it runs on. Try it with:"
      echo "  vector vrl -i /obs/vector/support.ndjson -p /obs/vector/redact.vrl -o"

  verify_done:
    timeout_seconds: 60
    run: |
      python3 - <<'PY'
      import json, re, subprocess, sys

      TOKEN = "[REDACTED]"
      EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      events = subprocess.run(["support-logs", "300"], capture_output=True, text=True, check=True).stdout
      open("/tmp/vrl-redact.in", "w").write(events)
      events = [json.loads(l) for l in events.splitlines()]
      try:
          open("/obs/vector/redact.vrl").close()
      except OSError:
          no("/obs/vector/redact.vrl is missing.")
      p = subprocess.run(["vector", "vrl", "-i", "/tmp/vrl-redact.in", "-p", "/obs/vector/redact.vrl", "-o"],
                         capture_output=True, text=True, env={"NO_COLOR": "1", "PATH": "/usr/local/bin:/usr/bin:/bin"})
      ansi = re.compile(r"\x1b\[[0-9;]*m")
      out = [ansi.sub("", l) for l in p.stdout.splitlines() if l.strip()]
      results = []
      for l in out:
          try:
              results.append(json.loads(l))
          except ValueError:
              results.append(l)
      if len(results) != len(events):
          text = [ansi.sub("", l) for l in (p.stdout + p.stderr).splitlines() if l.strip() and " INFO " not in l]
          runtime = [l for l in text if "call error" in l or l.startswith("error for")]
          if runtime and len(runtime) == len(text):
              no(f"redact.vrl failed on {len(events) - len([r for r in results if not isinstance(r, str)])} of {len(events)} events with a runtime error:",
                 f"  {runtime[0]}",
                 "In a pipeline, an event the remap fails on is dropped or passes through unredacted,",
                 "depending on drop_on_error. Handle every shape the events come in.")
          no("vector could not run /obs/vector/redact.vrl:", *["  " + l for l in text[:14]])
      for i, r in enumerate(results):
          if isinstance(r, str):
              no(f"redact.vrl failed on an event and returned an error instead of it:", f"  {r}",
                 "  event: " + json.dumps(events[i])[:150],
                 "A remap that errors drops the event or passes it through unredacted, depending",
                 "on drop_on_error. Handle every shape the events come in.")

      def scrub(v):
          if isinstance(v, str):
              return EMAIL.sub(TOKEN, v)
          if isinstance(v, list):
              return [scrub(x) for x in v]
          if isinstance(v, dict):
              return {k: scrub(x) for k, x in v.items()}
          return v

      def walk(orig, got, path=""):
          """Yield (kind, path, original, got) for every difference from the redacted original."""
          want = scrub(orig)
          if isinstance(orig, dict) and isinstance(got, dict):
              for k in orig:
                  if k not in got:
                      yield ("gone", f"{path}.{k}", orig[k], None)
                  else:
                      yield from walk(orig[k], got[k], f"{path}.{k}")
              for k in got:
                  if k not in orig:
                      yield ("added", f"{path}.{k}", None, got[k])
          elif isinstance(orig, list) and isinstance(got, list) and len(orig) == len(got):
              for i, (o, g) in enumerate(zip(orig, got)):
                  yield from walk(o, g, f"{path}[{i}]")
          elif type(orig) is not type(got) and not (isinstance(orig, float) and isinstance(got, int)):
              yield ("type", path, orig, got)
          elif got != want:
              if isinstance(got, str) and EMAIL.search(got):
                  yield ("leak", path, orig, got)
              else:
                  yield ("changed", path, orig, got)

      diffs = [d + (i,) for i, (e, r) in enumerate(zip(events, results)) for d in walk(e, r)]
      def worst(kind):
          hits = [d for d in diffs if d[0] == kind]
          return (hits[0], len({d[4] for d in hits})) if hits else (None, 0)

      d, n = worst("leak")
      if d:
          left = EMAIL.search(d[3]).group(0)
          norm = lambda p: re.sub(r"\[\d+\]", "[]", p)
          def changed(o, g, path=""):
              if isinstance(o, dict) and isinstance(g, dict):
                  return {p for k in o if k in g for p in changed(o[k], g[k], f"{path}.{k}")}
              if isinstance(o, list) and isinstance(g, list):
                  return {p for i, (a, b) in enumerate(zip(o, g)) for p in changed(a, b, f"{path}[]")}
              return {path} if o != g else set()
          touched = set().union(*(changed(e, r) for e, r in zip(events, results)))
          if norm(d[1]) not in touched:
              why = ["redact.vrl leaves this field untouched. Customer emails turn up in more than one",
                     "field, nested, and in lists."]
          else:
              why = [f"redact.vrl redacts addresses in this field, and missed {left!r}."]
              if left != left.lower():
                  why.append("Look at its capitals: domains and, in practice, addresses are case-insensitive.")
          no(f"an email is still in {d[1]}, in {n} of {len(events)} events. For example:",
             f"  {d[3]!r}", *why)
      d, n = worst("gone")
      if d:
          no(f"{d[1]} is missing from the output ({n} of {len(events)} events). It was {d[2]!r}.",
             "Dashboards, joins and alerts still read that field. Keep it, and mask the email in it.")
      d, n = worst("added")
      if d:
          no(f"the output has a field {d[1]} that the event did not have ({n} events): {d[3]!r}.",
             "Everything other than the emails has to come out exactly as it went in.")
      d, n = worst("type")
      if d:
          no(f"{d[1]} changed type: it was {d[2]!r} and is now {d[3]!r} ({n} events).",
             "Everything other than the emails has to come out exactly as it went in.")
      d, n = worst("changed")
      if d:
          want = scrub(d[2])
          if isinstance(d[3], str) and TOKEN in d[3]:
              no(f"{d[1]} lost text that is not an email address ({n} of {len(events)} events):",
                 f"  in:   {d[2]!r}", f"  out:  {d[3]!r}", f"  want: {want!r}",
                 "An address has a local part, an @ and a domain that ends in a dot and letters.")
          no(f"{d[1]} changed ({n} of {len(events)} events):",
             f"  in:   {d[2]!r}", f"  out:  {d[3]!r}", f"  want: {want!r}",
             f"Replace each email address with {TOKEN} and leave the rest of the text alone.")
      emails = sum(len(EMAIL.findall(json.dumps(e))) for e in events)
      print(f"PASS — {emails} email addresses redacted across {len(events)} events, and every other")
      print("field, order reference and release tag came through unchanged.")
      PY
