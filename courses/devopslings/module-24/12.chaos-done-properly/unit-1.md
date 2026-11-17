---
title: "Chaos, done properly"
---

## The situation

The architecture diagram says checkout survives losing a web node: two of
them behind HAProxy, health-checked every second. Nobody has ever turned
one off at a busy moment to see. You are going to, and you are going to do
it the way that earns the right to do it again: with a hypothesis that
could be wrong, a fault that is contained, a way to stop early, and a
write-up that reports what happened rather than what was expected.

`/ha/sre/chaos/README` lists the tools: `node kill|start` to break and
repair a node, and `/ha/sre/chaos/load`, which plays customer traffic and
records every request: when, its status, and which node served it.

## Your objectives

1. Write `/ha/sre/chaos/experiment`. Each run breaks one web node for a
   fixed time under traffic, records the traffic during the fault in
   `/ha/sre/chaos/runs/latest.log`, and leaves both nodes running however
   it ends: finished, aborted, or interrupted.
2. While the fault is in place, it watches the success rate and stops early,
   repairing, if it falls below your abort line.
3. Run it, and write `/ha/answers/chaos.txt`: the target, the hypothesis as
   a success rate, the duration, the abort line, what you observed, and
   whether the hypothesis held.

## What you're being graded on

- one web node is the target, for between 10 seconds and 5 minutes;
- the hypothesis is a success rate, so the data could prove it wrong, and
  the abort line is below it;
- `latest.log` shows the target really was down, and your observed rate and
  verdict match it;
- the grader runs your experiment twice: once it interrupts it after 8
  seconds, and the target must be repaired; once it kills the other web
  node mid-run, and the experiment must abort and repair.

## Try it yourself

Run the load on its own first, for 10 seconds, and look at what it records.
Then decide what you expect before you break anything: that is the
hypothesis, and writing it after the run is not an experiment.

<details>
<summary>Hint 1 — a hypothesis that could be wrong</summary>

"Checkout keeps working" is true of almost any outcome somebody wants to
call working. "At least 99.5% of requests succeed while web2 is down" is
true or false, and the log says which. Pick the number before you run.

</details>

<details>
<summary>Hint 2 — bounded</summary>

Three bounds, and each is code, not intent. A fixed duration. An abort that
looks at the traffic as it arrives, every second or so, over a short
window, and repairs if it goes under the line. And a trap, so that Ctrl-C,
a timeout or a kill still runs the repair: an experiment that leaves the
node down when it is interrupted has an unbounded blast radius.

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
# experiment — lose web2 for 30s under customer traffic.
# Aborts if under 80% of the last 5 seconds' requests succeed. Always repairs.
set -u
target=web2 duration=30 abort=80
log=/ha/sre/chaos/runs/latest.log
load=
repair() {
  [ -n "$load" ] && kill "$load" 2>/dev/null
  node start "$target" >/dev/null 2>&1
  for _ in $(seq 40); do curl -sf -o /dev/null --max-time 1 "http://$target:8080/health" && break; sleep 0.5; done
}
trap 'repair; echo "interrupted: $target repaired"; exit 130' INT TERM
# Traffic first, so the run records the moment the node goes, not only after.
/ha/sre/chaos/load "$((duration + 2))" > "$log" &
load=$!
sleep 2
node kill "$target" >/dev/null
end=$((SECONDS + duration))
while [ "$SECONDS" -lt "$end" ] && kill -0 "$load" 2>/dev/null; do
  sleep 1
  ok=$(awk -v since="$(date +%s.%N)" 'BEGIN { since -= 5 } $1 > since { n++; if ($2 == 200) g++ }
    END { print (n < 20 ? 100 : 100 * g / n) }' "$log")
  if awk -v ok="$ok" -v a="$abort" 'BEGIN { exit !(ok < a) }'; then
    repair
    echo "aborted: ${ok}% of the last 5s succeeded, under $abort%; $target repaired"
    exit 3
  fi
done
wait "$load"
load=
repair
echo "done: $target was down ${duration}s; data in $log"
```

Then the write-up, from the run:

```
target: web2
hypothesis: with web2 down, at least 99.5% of customer requests through www succeed
duration: 30
abort: 80
observed: 99.63
verdict: held
```

### What the data shows

A clean crash costs a handful of requests: the ones in flight to web2, and
the ones HAProxy sends there in the second or two before two failed health
checks take it out. Whether that is 99.5% or 99.9% depends on the traffic
and the timing, and that is exactly why the verdict comes from the log. A
hypothesis of 99.9% will often be refuted, and that is a good result: it
says the next thing to fix is HAProxy retrying a refused connection on the
other server (`retries` and `option redispatch`), and the next experiment
is the same one, to show it.

Try `node pause` instead of `node kill` once: a hung node holds requests
until they time out, which a crash never does. Same claim, different
failure, different answer.

</details>
