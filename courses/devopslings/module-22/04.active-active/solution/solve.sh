#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Sessions move out of each process and into the database both nodes share.
set -euo pipefail
sed -i 's/^SESSION_STORE=.*/SESSION_STORE=postgres/' /ha/app.env
grep SESSION_STORE /ha/app.env
