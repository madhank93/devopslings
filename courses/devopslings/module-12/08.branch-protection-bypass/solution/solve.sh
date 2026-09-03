#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three edits to the one rule. The push allowlist goes, because it is the only
# way onto main that does not pass through a pull request. The review
# requirement stays. And the check the pipeline reports becomes a condition of
# merging, named exactly as the forge reports it — workflow, job and event.
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
auth="-u devops:devopslings"
repo="devops/checkout"

curl -fsS $auth -X PATCH "${api}/repos/${repo}/branch_protections/main" \
  -H 'Content-Type: application/json' \
  -d '{"enable_push":false,
       "enable_push_whitelist":false,
       "push_whitelist_usernames":[],
       "required_approvals":1,
       "block_on_rejected_reviews":true,
       "enable_status_check":true,
       "status_check_contexts":["ci / build (push)"],
       "apply_to_admins":true}' >/dev/null

echo "main: direct pushes closed, one approval required, 'ci / build (push)' required"
