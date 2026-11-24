"""Per-host wall clocks for the obs-stack apps.

Containers share the kernel's CLOCK_REALTIME and a time namespace cannot
offset it, so a host with a wrong clock is emulated here. An app is a host
named after its script (/obs/apps/ledger.py runs on host "ledger"). When
/obs/hosts/<host>/clock-offset holds a number of seconds, every Python process
on that host reads wall-clock time that far off; monotonic clocks are left
alone, as on a real host. The file is re-read at most once a second, so a
change takes effect without a restart, like stepping a real clock.
"""
import os
import sys
import time

_host = os.path.splitext(os.path.basename(sys.argv[0] if sys.argv else ""))[0]
_path = f"/obs/hosts/{_host}/clock-offset"
_real_time, _real_time_ns, _mono = time.time, time.time_ns, time.monotonic
_state = {"checked": -2.0, "ns": 0}


def _offset_ns():
    now = _mono()
    if now - _state["checked"] >= 1:
        _state["checked"] = now
        try:
            _state["ns"] = int(float(open(_path).read().split()[0]) * 1e9)
        except (OSError, ValueError, IndexError):
            _state["ns"] = 0
    return _state["ns"]


if _host and os.path.isdir("/obs/hosts"):
    time.time_ns = lambda: _real_time_ns() + _offset_ns()
    time.time = lambda: _real_time() + _offset_ns() / 1e9
