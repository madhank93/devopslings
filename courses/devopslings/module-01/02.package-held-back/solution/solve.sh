#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# apt said "kept back" rather than "deferred", and the candidate was already
# 1.1, which rules out phasing and a pin respectively. That leaves a hold.
set -euo pipefail

install -d /root/answers
echo hold > /root/answers/reason

# apt-mark showhold lists them. Removing the hold is the whole fix; the upgrade
# then behaves normally.
apt-mark unhold ledger-tools >/dev/null

apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq --only-upgrade ledger-tools >/dev/null

# Leave nothing held behind — the check looks at the whole list, not just this
# package, because the next nightly upgrade will skip anything still on it.
for p in $(apt-mark showhold); do apt-mark unhold "$p" >/dev/null; done
