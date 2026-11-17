#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# alice commands and stays out of the logs; bob operates; carol writes every
# update. SEV2 at declaration (8%), SEV1 when 41% arrives, never lowered.
# Updates: 10:08, then within 15 minutes of the escalation and every 15 after.
set -euo pipefail
cat > /ha/answers/incident.txt <<'TXT'
declared: 10:05
commander: alice
ops_lead: bob
comms_lead: carol
resolved: 10:52

severity: 10:05 | SEV2
severity: 10:18 | SEV1

update: 10:08 | carol | Some customers cannot complete checkout; we are investigating. Next update by 10:38.
update: 10:20 | carol | Checkout is failing for many customers; raised to SEV1. Next update by 10:35.
update: 10:35 | carol | Cause found in this morning's 09:55 release; preparing to roll it back. Next update by 10:50.
update: 10:47 | carol | Rollback in progress, most checkouts working again. Next update by 11:02.
update: 10:52 | carol | Resolved: checkout is back to normal. A postmortem will follow.

task: 10:05 | alice | coordinate | open the incident channel, assign roles, set the update cadence
task: 10:06 | bob   | investigate | checkout errors: which step, since when
task: 10:06 | carol | communicate | collect and link the support tickets
task: 10:18 | alice | decide | raise to SEV1
task: 10:31 | alice | decide | stays commander; asks bob what he needs from the payment client's authors
task: 10:35 | bob   | investigate | connection pool exhausted since the 09:55 deploy
task: 10:38 | alice | decide | roll back the 09:55 deploy
task: 10:38 | bob   | change | roll back the 09:55 deploy
task: 10:52 | alice | decide | declare resolved; postmortem owner: bob
TXT
