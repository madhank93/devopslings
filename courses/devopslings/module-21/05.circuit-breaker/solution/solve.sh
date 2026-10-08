#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Closed: every call goes through; 5 consecutive failures open it.
# Open: nothing goes through for 5s.
# Half-open: exactly one trial; success closes, failure reopens.
#
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > "$DEVOPSLINGS_ROOT/scratch/circuit-breaker/breaker.py" <<'PY'
import time

TIMEOUT = (1.0, 2.0)


class Breaker:
    THRESHOLD = 5
    COOLDOWN = 5.0

    def __init__(self):
        self.state = "closed"
        self.failures = 0
        self.opened_at = 0.0
        self.trial_in_flight = False

    def allow(self):
        if self.state == "closed":
            return True
        if self.state == "open":
            if time.monotonic() - self.opened_at < self.COOLDOWN:
                return False
            self.state = "half-open"
            self.trial_in_flight = False
        if self.trial_in_flight:
            return False
        self.trial_in_flight = True
        return True

    def success(self):
        self.state = "closed"
        self.failures = 0
        self.trial_in_flight = False

    def failure(self):
        self.failures += 1
        self.trial_in_flight = False
        if self.state == "half-open" or self.failures >= self.THRESHOLD:
            self.state = "open"
            self.opened_at = time.monotonic()
PY
