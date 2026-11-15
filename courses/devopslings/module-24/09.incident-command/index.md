---
kind: lesson
title: "Incident command"
description: |
  Checkout is failing, three people are in the channel, and all three are
  reading logs. Run the incident: give everyone a role they keep, call the
  severity the published criteria give, keep the updates on cadence, and
  keep the commander out of the debugger.
name: incident-command
slug: incident-command
createdAt: "2026-11-14"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/ic
      cat > /var/lib/devopslings/ic-grade.py <<'PY'
      import re
      import sys

      ANS = "/ha/answers/incident.txt"
      PEOPLE = {"alice", "bob", "carol"}
      KINDS = {"investigate", "change", "coordinate", "communicate", "decide"}
      FACT_SEV1 = 18          # 10:18, checkout errors 41%
      RESOLVED = 52           # 10:52, back to normal


      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)


      def minute(s, what):
          m = re.fullmatch(r"10:([0-5][0-9])", s.strip())
          if not m:
              fail(f"{what} has the time '{s.strip()}'; times are HH:MM between 10:00 and 10:59.")
          return int(m.group(1))


      try:
          lines = [l.split("#", 1)[0].strip() for l in open(ANS)]
      except OSError:
          fail(f"{ANS} is missing.")
      fields, rows = {}, {"severity": [], "update": [], "task": []}
      for l in lines:
          k, sep, v = l.partition(":")
          k = k.strip().lower()
          if not sep:
              continue
          if k in rows:
              rows[k].append([p.strip() for p in v.split("|")])
          else:
              fields[k] = v.strip().lower()

      for k in ("declared", "commander", "ops_lead", "comms_lead", "resolved"):
          if fields.get(k, "?") in ("", "?"):
              fail(f"{k} in {ANS} is not filled in.")
      roles = {"commander": fields["commander"], "ops_lead": fields["ops_lead"], "comms_lead": fields["comms_lead"]}
      for role, who in roles.items():
          if who == "dan":
              fail(f"{role} is dan. dan is on holiday until Monday: a role given to someone who is not",
                   "there is a role nobody holds.")
          if who not in PEOPLE:
              fail(f"{role} is '{who}'; the people on the incident are alice, bob and carol.")
      if len(set(roles.values())) < 3:
          dup = [w for w in PEOPLE if list(roles.values()).count(w) > 1][0]
          fail(f"{dup} holds two roles. With three people and three roles, each holds one: the moment the",
               "commander is also fixing something, nobody is watching the whole incident.")
      ic, ops, comms = roles["commander"], roles["ops_lead"], roles["comms_lead"]

      declared = minute(fields["declared"], "declared")
      if not 4 <= declared <= 9:
          fail(f"declared is 10:{declared:02d}. The page was acknowledged at 10:04, and the criteria say an",
               "incident is declared within five minutes of that.")
      resolved = minute(fields["resolved"], "resolved")
      if resolved != RESOLVED:
          fail(f"resolved is 10:{resolved:02d}. The incident is resolved when customers are back to normal:",
               "the timeline says when the error rate returned to its usual 0.2%.")

      # Severity: the call in force at each minute must match the criteria.
      calls = []
      for r in rows["severity"]:
          if len(r) != 2 or not re.fullmatch(r"sev[123]", r[1].lower()):
              fail(f"'severity: {' | '.join(r)}' should read 'severity: HH:MM | SEVn'.")
          calls.append((minute(r[0], "a severity line"), int(r[1][-1])))
      calls.sort()
      if not calls or calls[0][0] > declared:
          fail("the first severity call has to be made when the incident is declared.")
      for t, s in calls:
          if t < declared or t > resolved:
              fail(f"there is a severity call at 10:{t:02d}, outside the incident (10:{declared:02d} to 10:{resolved:02d}).")
      first = calls[0][1]
      if first == 1:
          fail("the incident was declared SEV1. At declaration the checkout error rate was 8%: the criteria",
               "make 1-25% of checkouts failing SEV2. Calling everything SEV1 is how SEV1 stops meaning",
               "anything, and how a team ends up on a 15-minute update cadence for a degraded feature.")
      if first != 2:
          fail(f"the incident was declared SEV{first}. At declaration the checkout error rate was 8%: the",
               "criteria make 1-25% of checkouts failing SEV2.")
      prev = 2
      for t, s in calls[1:]:
          if s > prev:
              if t < FACT_SEV1:
                  fail(f"severity is raised to SEV{s} at 10:{t:02d}, before any fact that meets SEV1.")
          if s < prev:
              fail(f"severity is lowered to SEV{s} at 10:{t:02d}, before the incident is resolved. The criteria",
                   "never lower severity during an incident: an error rate that is falling is a rollback",
                   "half done, and it can rise again.")
          prev = s
      escal = [t for t, s in calls if s == 1]
      if not escal:
          fail("severity is never raised. At 10:18 the checkout error rate is 41%, over the criteria's 25%",
               "line for SEV1. Severity is re-assessed when new facts arrive.")
      if escal[0] > FACT_SEV1 + 5:
          fail(f"severity goes to SEV1 at 10:{escal[0]:02d}. The 41% error rate was known at 10:18; the",
               "re-assessment belongs within minutes of the fact, not after it.")

      # Updates: by the comms lead, at the cadence in force, and one at resolution.
      ups = []
      for r in rows["update"]:
          if len(r) < 3 or not r[2]:
              fail(f"'update: {' | '.join(r)}' should read 'update: HH:MM | who | what it says'.")
          t, who = minute(r[0], "an update line"), r[1].lower()
          if who != comms:
              fail(f"the update at 10:{t:02d} is posted by {who}. Status updates are the communications",
                   f"lead's job ({comms}); when anyone else writes them, the people fixing are distracted",
                   "and the updates stop when things get busy.")
          ups.append(t)
      ups.sort()
      sev_at = lambda m: [s for t, s in calls if t <= m][-1]
      changed = sorted({t for t, _ in calls})
      last = declared
      for m in range(declared, resolved + 1):
          if m in ups:
              last = m
          cadence = 15 if sev_at(m) == 1 else 30
          since = max([last] + [t for t in changed if t <= m])
          if m - since > cadence:
              fail(f"no status update between 10:{since:02d} and 10:{m:02d}, while the incident was SEV{sev_at(m)}.",
                   f"The criteria say every {cadence} minutes at SEV{sev_at(m)}, counted from the last update or",
                   "the last change of severity. Silence is when customers and executives start",
                   "asking the people fixing it directly.")
      if not any(t >= resolved for t in ups):
          fail("there is no status update at resolution. The last update is what tells everyone waiting",
               "that they can stop waiting.")

      # Tasks: each role does its own kind of work, and the commander does not debug.
      own = {"investigate": ops, "change": ops, "communicate": comms}
      for r in rows["task"]:
          if len(r) < 4:
              fail(f"'task: {' | '.join(r)}' should read 'task: HH:MM | who | kind | what'.")
          t, who, kind = minute(r[0], "a task line"), r[1].lower(), r[2].lower()
          if kind not in KINDS:
              fail(f"the task at 10:{t:02d} has the kind '{kind}'; kinds are {', '.join(sorted(KINDS))}.")
          if who == ic and kind in ("investigate", "change"):
              fail(f"at 10:{t:02d} the commander, {ic}, will {kind}: '{r[3]}'.",
                   "A commander who debugs has stopped commanding. While their head is in the logs, nobody",
                   "is tracking the severity, the cadence or the next decision. If the commander is the best",
                   "debugger in the room, hand command to someone else first, or keep command and say no.")
          if kind in own and who != own[kind]:
              fail(f"at 10:{t:02d} {who} has a task of kind '{kind}', which is the {'operations' if own[kind] == ops else 'communications'} lead's ({own[kind]}).")
          if kind in ("coordinate", "decide") and who != ic:
              fail(f"at 10:{t:02d} {who} will {kind}. Coordinating and deciding are the commander's ({ic}):",
                   "one person makes the calls, so two people never make different ones.")
      if not any(r[2].lower() == "decide" and r[1].lower() == ic for r in rows["task"] if len(r) >= 4):
          fail("the commander makes no decision. Someone decided to roll back the 09:55 deploy at 10:38;",
               "in this incident that call is the commander's.")
      if not any(r[2].lower() == "change" for r in rows["task"] if len(r) >= 4):
          fail("no task changes anything. The incident ended with the 09:55 deploy rolled back: who did it?")

      print(f"roles: {ic} commands, {ops} operates, {comms} communicates; nobody holds two")
      print(f"severity: SEV2 at 10:{declared:02d}, SEV1 at 10:{escal[0]:02d}, never lowered")
      print(f"{len(ups)} status updates, none late, the last at resolution")
      print(f"the commander coordinated and decided, and did not debug")
      PY
      cat > /ha/ic/criteria.md <<'MD'
      # Incident criteria (published; the same for every incident)

      ## Severity
      SEV1  more than 25% of checkouts failing, or customer data lost or exposed
      SEV2  1-25% of checkouts failing, or a customer-facing feature unavailable
      SEV3  internal systems only, or under 1% of checkouts failing

      Declare within 5 minutes of the page being acknowledged.
      Re-assess severity whenever a new fact arrives. Never lower it before the
      incident is resolved.

      ## Roles, one person each
      incident commander   coordinates and decides. Does not investigate or change systems.
      operations lead      investigates and changes systems.
      communications lead  writes every status update.

      ## Status updates
      SEV1 every 15 minutes, SEV2 every 30, counted from the last update or the
      last change of severity, whichever is later. One more at resolution.
      MD
      cat > /ha/ic/people.txt <<'TXT'
      alice   staff engineer; wrote most of the payment client
      bob     SRE, on call this week
      carol   support lead
      dan     engineering manager; on holiday until Monday
      TXT
      cat > /ha/ic/timeline.txt <<'TXT'
      # 2026-11-14. Facts arrive when written here; nobody knows them earlier.
      10:00  page: checkout error rate 8% for 5 minutes. Browse and search normal.
      10:04  bob acknowledges the page.
      10:06  carol: support has 3 tickets, "card declined" on cards that work elsewhere.
      10:12  bob: the errors are all in the payment step. The provider's status page is green.
      10:18  page: checkout error rate 41%.
      10:24  bob: payment calls time out at our 5 s limit; the provider says their latency is normal.
      10:31  alice: "I wrote half of that client. Want me to pull the logs myself?"
      10:35  bob: the payment client's connection pool has been exhausted since the 09:55 deploy.
      10:38  bob: rolling back the 09:55 deploy takes about 6 minutes.
      10:44  checkout error rate 3% and falling; the rollback is half done.
      10:52  checkout error rate 0.2%, as before 09:55. Rollback complete.
      TXT
      cat > /ha/answers/incident.txt <<'TXT'
      # The incident as you ran it. Times are HH:MM. '#' starts a comment.
      declared: ?
      commander: ?
      ops_lead: ?
      comms_lead: ?
      resolved: ?

      # Every severity call, in order, from the declaration:
      #   severity: HH:MM | SEVn
      # Every status update, from the declaration to the resolution:
      #   update: HH:MM | who | what it says
      # Who did what, as it happened. kind: investigate, change, coordinate,
      # communicate or decide.
      #   task: HH:MM | who | kind | what
      TXT
      echo "scenario ready — 10:04, bob has just acknowledged the page."
      echo
      echo "  the criteria:     /ha/ic/criteria.md"
      echo "  who is here:      /ha/ic/people.txt"
      echo "  what happens:     /ha/ic/timeline.txt"
      echo "  how you ran it:   /ha/answers/incident.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      g=/var/lib/devopslings/ic-grade.py
      if [ ! -f "$g" ]; then
        echo "not yet: the scenario's rubric is missing. Reset the lesson."
        exit 1
      fi
      python3 "$g"
      echo
      echo "PASS — roles held, severity by the criteria, updates on cadence, and a commander who commands."
---
