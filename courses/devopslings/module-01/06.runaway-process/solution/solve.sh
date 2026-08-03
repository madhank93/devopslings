#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Only worker 3 spins. The other two workers and the cache warmer are innocent
# and must be left running; stopping the fleet also flattens the CPU graph but
# fails the check.
set -euo pipefail

systemctl stop queue-worker@3.service
