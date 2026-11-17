---
kind: lesson
title: "The postmortem"
description: |
  The checkout incident from incident-command is over, and the channel has
  already decided whose fault it was. Write the postmortem anyway: a
  timeline from the data rather than from memory, the conditions that let
  one config change take checkout down for most of an hour, and actions
  that change those conditions, each with someone's name on it.
name: the-postmortem
slug: the-postmortem
createdAt: "2026-11-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      g=/var/lib/devopslings/pm
      d=/ha/sre/postmortem
      mkdir -p "$g" "$d"
      cat > "$g/errors.py" <<'PY'
      # Checkout, minute by minute, 09:40 to 11:00 on 2026-11-14.
      def pct(m):  # error rate in % at minute m after 09:00
          if m < 56 or m >= 112:
              return 0.2
          prof = {56: 4, 57: 6, 58: 7, 59: 8, 60: 8, 61: 9, 62: 9, 63: 10, 64: 10, 65: 11, 66: 11,
                  67: 12, 68: 12, 69: 13, 70: 14, 71: 15, 72: 17, 73: 20, 74: 24, 75: 29,
                  76: 34, 77: 38, 98: 41, 99: 36, 100: 30, 101: 24, 102: 17, 103: 10, 104: 3,
                  105: 2.5, 106: 2, 107: 1.6, 108: 1.2, 109: 0.9, 110: 0.6, 111: 0.4}
          return prof.get(m, 41)
      print("minute,checkouts,failed")
      for m in range(40, 121):
          c = 880 + (m * 37) % 61
          print(f"{9 + m // 60:02d}:{m % 60:02d},{c},{round(c * pct(m) / 100)}")
      PY
      python3 "$g/errors.py" > "$g/errors.csv"
      cp "$g/errors.csv" "$d/errors.csv"
      cat > "$d/deploys.log" <<'LOG'
      2026-11-14T08:30:12Z checkout v411  gita   search filters on the order history page
      2026-11-14T09:55:08Z checkout v412  erin   payment client: share one connection pool per process
                                                 (payment.pool.max 20 -> 4, set per process, not per worker)
                                                 review: approved by bob, "LGTM, config only"
                                                 canary: 5 min on web2 at 07:00-equivalent traffic, 0 errors
      2026-11-14T10:38:40Z checkout v411  bob    rollback (rebuild of v411: build 2m50s, push 1m, roll out 2m10s)
      LOG
      cat > "$d/pages.log" <<'LOG'
      2026-11-14T10:00:00Z FIRING  CheckoutErrorRate  checkout error rate 8% (> 5% for 4m)
      2026-11-14T10:04:12Z ACK     CheckoutErrorRate  bob
      2026-11-14T10:18:00Z FIRING  CheckoutErrorRate  checkout error rate 41%
      2026-11-14T10:53:00Z RESOLVED CheckoutErrorRate
      LOG
      cat > "$d/chat.log" <<'LOG'
      10:05 alice   I'm commander. bob ops, carol comms. SEV2.
      10:06 carol   support has 3 tickets, "card declined" on cards that work elsewhere
      10:12 bob     errors are all in the payment step. provider status page is green
      10:18 alice   41% now. SEV1.
      10:24 bob     payment calls time out at our 5s limit; provider says their latency is normal
      10:31 alice   (I wrote half that client. tempted to pull the logs myself. staying IC.)
      10:35 bob     payment client pool exhausted since the 09:55 deploy. every worker queues on 4 connections
      10:36 gita    erin's change again. she should have load tested it
      10:37 bob     it passed review and canary. canary never runs a payment
      10:38 alice   roll back the 09:55 deploy. bob go
      10:38 bob     rolling back. it's a rebuild, ~6 min
      10:44 carol   errors 3% and falling
      10:52 bob     rollback complete, 0.2%
      10:52 alice   resolved. postmortem owner: bob
      LOG
      cat > "$d/team.txt" <<'TXT'
      alice   staff engineer; wrote most of the payment client
      bob     SRE, on call that week
      carol   support lead
      dan     engineering manager
      erin    engineer; made the 09:55 change
      gita    engineer
      TXT
      cat > /ha/answers/postmortem.txt <<'TXT'
      # Postmortem: checkout payment failures, 2026-11-14. '#' starts a comment.
      # Times are HH:MM, from the data in /ha/sre/postmortem.

      impact_start: ?       # the first minute customers failed more than the usual 0.2%
      detected: ?           # when the system told a human
      resolved: ?           # when failures were back to the usual 0.2%
      failed_checkouts: ?   # checkouts that failed because of the incident: over the usual 0.2%

      # The timeline, in order:
      #   timeline: HH:MM | what happened
      # Contributing factors: the conditions that let it happen, or made it last.
      #   factor: ...
      # Action items, one owner each (from team.txt) and a due date:
      #   action: owner | what | YYYY-MM-DD
      TXT
      cat > "$g/pm-grade.py" <<'PY'
      import csv
      import re
      import sys

      ANS = "/ha/answers/postmortem.txt"
      PEOPLE = {"alice", "bob", "carol", "dan", "erin", "gita"}
      WHO = r"(alice|bob|carol|dan|erin|gita|she|he|someone|somebody|the (engineer|reviewer|developer|author))"
      BLAME = re.compile(rf"\b(blame\w*|careless\w*|negligen\w*|sloppy|incompeten\w*|human error|"
                         rf"{WHO}\s+(should(n't| not)? have|failed to|forgot|neglected|ignored|didn't bother|messed up|broke)|"
                         rf"{WHO}'s\s+(\w+\s+)?(mistake|error|fault|bug|blunder)|{WHO}'s\s+\w+\s+(broke|caused|took down))\b", re.I)
      TRY_HARDER = re.compile(r"\b(be (more )?careful|carefully|remember to|pay (more )?attention|double[- ]check|"
                              r"retrain\w*|training|remind\w*|try harder)\b", re.I)


      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)


      def hhmm(s, what):
          m = re.fullmatch(r"(\d\d):(\d\d)", (s or "").strip())
          if not m:
              fail(f"{what} is '{(s or '').strip() or 'missing'}'; times are HH:MM.")
          return m.group(0)


      rows = list(csv.DictReader(open("/var/lib/devopslings/pm/errors.csv")))
      bad = [r for r in rows if int(r["failed"]) > round(int(r["checkouts"]) * 0.002) + 1]
      START, END = bad[0]["minute"], bad[-1]["minute"]
      window = [r for r in rows if START <= r["minute"] <= END]
      EXCESS = sum(int(r["failed"]) - int(r["checkouts"]) * 0.002 for r in window)
      RESOLVED = rows[rows.index(window[-1]) + 1]["minute"]

      try:
          lines = [l.split("#", 1)[0].strip() for l in open(ANS)]
      except OSError:
          fail(f"{ANS} is missing.")
      fields, rep = {}, {"timeline": [], "factor": [], "action": []}
      for l in lines:
          k, sep, v = l.partition(":")
          k = k.strip().lower()
          if not sep:
              continue
          if k in rep:
              rep[k].append(v.strip())
          else:
              fields[k] = v.strip()
      for k in ("impact_start", "detected", "resolved", "failed_checkouts"):
          if fields.get(k, "?") in ("", "?"):
              fail(f"{k} in {ANS} is not filled in.")

      s = hhmm(fields["impact_start"], "impact_start")
      if s != START:
          why = {"10:00": "That is when the page fired. Customers were failing before anyone was told; the impact starts with them.",
                 "09:55": "That is the deploy. The impact starts with the first minute customers failed.",
                 "10:04": "That is when the page was acknowledged; customers had been failing for a while."}.get(s, "")
          fail(f"impact_start is {s}; errors.csv has the first minute above 0.2% at {START}.", why)
      dt = hhmm(fields["detected"], "detected")
      if dt != "10:00":
          why = ("10:04 is when bob acknowledged it. Detection is the system telling a human: the page, at 10:00."
                 if dt == "10:04" else "pages.log has when the system first told a human.")
          fail(f"detected is {dt}.", why)
      r = hhmm(fields["resolved"], "resolved")
      if r != RESOLVED:
          fail(f"resolved is {r}; errors.csv is back to 0.2% at {RESOLVED}.",
               "The rollback finishing is a cause; resolution is what customers see.")
      try:
          fc = float(re.sub(r"[ ,]", "", fields["failed_checkouts"]))
      except ValueError:
          fail(f"failed_checkouts is '{fields['failed_checkouts']}'; it needs a number.")
      if abs(fc - EXCESS) > 0.005 * EXCESS:
          tot = sum(int(r["failed"]) for r in window)
          late = sum(int(r["failed"]) - int(r["checkouts"]) * 0.002 for r in window if r["minute"] >= "10:00")
          why = ("That counts every failure in the window, including the 0.2% that fail on any day." if abs(fc - tot) <= 0.005 * tot else
                 "That counts from the page at 10:00; customers were failing from " + START + "." if abs(fc - late) <= 0.005 * late else
                 f"From {START} to {END}, failures over 0.2% of each minute's checkouts.")
          fail(f"failed_checkouts is {fc:g}; the data gives about {EXCESS:.0f}.", why)

      # The timeline.
      times = []
      for t in rep["timeline"]:
          w, _, what = t.partition("|")
          times.append(hhmm(w, f"the timeline line '{t}'"))
          if not what.strip():
              fail(f"'timeline: {t}' says when, but not what happened.")
      if times != sorted(times):
          fail("the timeline is out of order.")
      need = {"09:55": "the deploy that started it (deploys.log)", START: "the first failures (errors.csv)",
              "10:00": "the page (pages.log)", "10:38": "the rollback starting (deploys.log)", RESOLVED: "the resolution"}
      for t, what in need.items():
          if t not in times:
              fail(f"the timeline has nothing at {t}: {what}.",
                   "A postmortem timeline starts before anyone knew, and ends when customers were fine.")

      # Blame, wherever it is written.
      for k in rep:
          for t in rep[k]:
              m = BLAME.search(t)
              if m:
                  fail(f"'{k}: {t}' says '{m.group(0)}'.",
                       "That is a judgement of a person, and a postmortem that judges people gets less",
                       "honest every time. Say what happened and what in the system allowed it.")

      # Contributing factors: conditions, more than the trigger.
      if len(rep["factor"]) < 3:
          fail(f"there {'is' if len(rep['factor']) == 1 else 'are'} {len(rep['factor'])} contributing factor(s). One change started it;",
               "what let it through review and canary, kept it unnoticed, and kept it live for an hour?")
      for t in rep["factor"]:
          who = [p for p in PEOPLE if re.search(rf"\b{p}\b", t, re.I)]
          if who:
              fail(f"the factor '{t}' names {who[0]}.",
                   "Contributing factors are conditions in the system: the review that approved it, the",
                   "canary that could not see it. A person is never the condition; the place they stood is.")
      text = " ".join(rep["factor"]).lower()
      if not re.search(r"canary|alert|page|detect|monitor|dashboard|saturat|metric|test", text):
          fail("no factor is about why it was not caught: the canary passed it, and nothing watched the pool.")
      if not re.search(r"roll ?back|revert|rebuild|6 min|six min|recover", text):
          fail("no factor is about why it lasted: the fix was ready at 10:38 and took until 10:52.",
               "deploys.log says why the rollback took that long.")

      # Action items: one owner each, a date, and a change to the system.
      if len(rep["action"]) < 3:
          fail(f"there {'is' if len(rep['action']) == 1 else 'are'} {len(rep['action'])} action item(s); each contributing factor needs at least one.")
      for t in rep["action"]:
          p = [x.strip() for x in t.split("|")]
          if len(p) != 3:
              fail(f"'action: {t}' should read 'action: owner | what | YYYY-MM-DD'.")
          owner, what, due = p[0].lower(), p[1], p[2]
          if owner not in PEOPLE:
              fail(f"an action is owned by '{p[0]}': {what}",
                   "An action owned by a team, 'TBD' or everyone is owned by nobody, and it is still open at",
                   "the next incident. One person from team.txt, who will see it through.")
          if not re.fullmatch(r"2026-(11-(1[5-9]|2\d|30)|12-\d\d)|2027-\d\d-\d\d", due):
              fail(f"an action is due '{due}': {what}", "Give it a date after the incident, as YYYY-MM-DD.")
          m = TRY_HARDER.search(what)
          if m:
              fail(f"the action '{what}' asks for '{m.group(0)}'.",
                   "Asking people to try harder is blame written as an action; it fails the next tired",
                   "person the same way. Change what they work with: a check, an alert, a faster path.")

      print(f"impact {START} to {END}, detected 10:00, resolved {RESOLVED}: about {EXCESS:.0f} failed checkouts")
      print(f"timeline of {len(times)} events, {len(rep['factor'])} contributing factors, none of them a person")
      print(f"{len(rep['action'])} actions, each with one owner and a date")
      PY
      echo "scenario ready — the 2026-11-14 checkout incident is resolved. Time for the postmortem."
      echo
      echo "  the data:      /ha/sre/postmortem/  (errors.csv, deploys.log, pages.log, chat.log, team.txt)"
      echo "  your write-up: /ha/answers/postmortem.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      g=/var/lib/devopslings/pm
      if [ ! -f "$g/pm-grade.py" ] || [ ! -f "$g/errors.csv" ]; then
        echo "not yet: the scenario's files are missing. Reset the lesson."
        exit 1
      fi
      python3 "$g/pm-grade.py"
      echo
      echo "PASS — a timeline from the data, conditions instead of culprits, and actions somebody owns."
---
