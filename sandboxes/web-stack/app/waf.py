#!/usr/bin/env python3
import os
import re
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("WAF_PORT", "8090"))
RULES_PATH = os.environ.get("WAF_RULES", "/etc/waf/rules.conf")
CONF_PATH = os.environ.get("WAF_CONF", "/etc/waf/waf.conf")

_RULES = []
_RULES_MTIME = -1.0


def load_rules():
    global _RULES, _RULES_MTIME
    try:
        stat = os.stat(RULES_PATH)
        mtime = stat.st_mtime
        if mtime != _RULES_MTIME:
            new_rules = []
            with open(RULES_PATH) as f:
                for line in f:
                    line = line.rstrip()
                    if not line or line[0] == "#":
                        continue
                    if "\t" not in line:
                        continue
                    name, regex = line.split("\t", 1)
                    try:
                        compiled = re.compile(regex)
                    except re.error as e:
                        print(f"warning: bad rule {name}: {e}", file=sys.stderr)
                        continue
                    new_rules.append((name, compiled))
            _RULES = new_rules
            _RULES_MTIME = mtime
    except FileNotFoundError:
        _RULES = []
        _RULES_MTIME = -1.0
    return _RULES


def budget_ms():
    try:
        with open(CONF_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if key == "budget_ms":
                    try:
                        return int(value)
                    except ValueError:
                        return 0
    except FileNotFoundError:
        pass
    return 0


def match_unbounded(rx, target):
    return rx.search(target) is not None


def match_bounded(rx, target, ms):
    pid = os.fork()
    if pid == 0:
        try:
            hit = rx.search(target) is not None
        except Exception:
            os._exit(12)
        os._exit(10 if hit else 11)

    deadline = time.monotonic() + ms / 1000.0
    while True:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            code = os.WEXITSTATUS(status)
            if code == 10:
                return "match"
            return "nomatch"
        if time.monotonic() >= deadline:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            return "overbudget"
        time.sleep(0.002)


def evaluate(target):
    start = time.monotonic()
    budget = budget_ms()
    rules = load_rules()
    for name, rx in rules:
        if budget == 0:
            hit = match_unbounded(rx, target)
        else:
            result = match_bounded(rx, target, budget)
            if result == "overbudget":
                return ("overbudget", name, round((time.monotonic() - start) * 1000, 1))
            hit = result == "match"
        if hit:
            return ("block", name, round((time.monotonic() - start) * 1000, 1))
    elapsed = round((time.monotonic() - start) * 1000, 1)
    return ("allow", "", elapsed)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "3")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        target = self.headers.get("X-Original-URI", "")
        verdict, rule_name, elapsed = evaluate(target)
        if verdict == "allow":
            self.send_response(204)
            self.end_headers()
        elif verdict == "block":
            self.send_response(403)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "8")
            self.send_header("X-WAF-Rule", rule_name)
            self.end_headers()
            self.wfile.write(b"blocked\n")
        elif verdict == "overbudget":
            self.send_response(503)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "17")
            self.send_header("X-WAF-Overbudget", rule_name)
            self.end_headers()
            self.wfile.write(b"rule over budget\n")

        print(
            f"waf verdict={verdict} rule={rule_name} ms={elapsed} uri={target}",
            file=sys.stderr,
            flush=True,
        )

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    # Single-threaded on purpose: one request is evaluated at a time, so a rule
    # that takes seconds to decide holds up every other request behind it. That
    # is what an edge filter with no time budget does to a site.
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
