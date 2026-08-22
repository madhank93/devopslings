#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The one component of the path that the worker could not traverse. Only the
# execute bit goes back: the directory was never meant to be listable or
# writable by anyone but its owner.
chmod o+x /srv/www/example

install -d /root/answers
cat > /root/answers/perms.md <<'ANS'
blocked_path: /srv/www/example
missing_permission: execute
ANS
