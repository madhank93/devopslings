---
title: "one rule, every request, and a regex that stops to think"
---

## The situation

Most of the site is fine:

```
$ curl -s -o /dev/null -w '%{time_total}\n' http://127.0.0.1/health
0.003
```

Some of it is not:

```
$ q=$(python3 -c 'print("1"*600)')
$ curl -s -o /dev/null -w '%{time_total}\n' "http://127.0.0.1/asset.js?q=${q}x"
6.002
```

Six seconds, and the origin never heard about it. The time was spent in front:

```
$ journalctl -u waf -n 1 --no-pager
waf verdict=allow rule=sqli-inline-assignment ms=6001.4 uri=/asset.js?q=111…1x
```

Six seconds to decide that a request was *fine*.

## Every request goes through the rule, and the rule is a regex

nginx's `auth_request` turns one incoming request into two: before proxying
anything it asks a filter about it and waits for the verdict.

```nginx
location = /_waf {
    internal;
    proxy_pass http://127.0.0.1:8090/check;
    proxy_set_header X-Original-URI $request_uri;
}

location / {
    auth_request /_waf;
    proxy_pass http://172.32.0.11:8080;
}
```

The filter's latency is therefore the site's latency, on every route, for every
request. And this filter answers one request at a time, so its latency is also
its queue.

The rule it is running is written to catch an assignment expression in a
request — the shape of an injected payload:

```
(?:\"|'|\]|\}|\\|\d|(?:nan|infinity|…)|\+)+[)]*;?((?:\s|-|~|!|{}|\|\||\+)*.*(?:.*=.*))
```

## Why a regex takes six seconds

A backtracking engine does not decide whether a string matches; it searches for
a way to make it match, and gives up only when it has tried every way. Two
constructs make "every way" enormous.

**Adjacent unbounded quantifiers.** The tail here is `.*(?:.*=.*)` — `.*`
immediately followed by another `.*`. For a 600-character input the engine must
consider every split of those characters between the first `.*` and the second,
because any of them might be the one that lets the `=` land where it needs to.
That is quadratic on its own; wrapped in the rest of the rule, with a `+` over a
character class that the tail can also match, each of those splits is retried
against every division of the prefix. The work grows as a polynomial with a high
degree — 300 characters is 0.4 seconds, 600 is six, 800 takes half an hour.

The engine is not confused. It is doing exactly what it was asked, and what it
was asked is exponentially more than the author imagined.

**The input is not an attack.** It has no quotes, no semicolons and nothing
injected. It is a long string of digits. The rule was never going to block it —
it just took six seconds to say so, which is the difference between a rule that
is wrong and a rule that is slow.

This is the July 2019 Cloudflare outage almost exactly. One WAF rule containing
`.*.*=.*` was deployed globally, CPU on every machine in every datacentre went
to 100 percent, and the network stopped serving traffic. Nothing was
compromised, nothing was corrupted, and the rule blocked nothing it was not
supposed to block.

## Making it fast without making it weaker

The tempting fix is to delete the rule. That is not a fix; it is an outage
traded for an exposure. A rule has a job, and this repository writes it down:

```
$ cat /root/waf-corpus/block
/api?x=1;a=b
/q?p=';a=1
$ cat /root/waf-corpus/allow
/health
/asset.js?v=3
```

Two changes keep every one of those verdicts and remove the search.

**Drop the redundant `.*`.** `(?:.*=.*)` after a `.*` says nothing that `(?:=.*)`
does not; the leading `.*` is already there. This is the change Cloudflare
shipped.

**Make the prefix possessive.** `(?:…)+` becomes `(?:…)++`: having consumed as
much as it can, the engine is forbidden to give any of it back. Where a
possessive quantifier is correct it does not change what matches — it only
removes retries that could never succeed. `(?>…)`, an atomic group, is the same
idea with different syntax.

Both together take the 600-character request from six seconds to under a
millisecond, with the corpus verdicts unchanged.

Note the trap: making the *tail* possessive — `(?:.*+=.*)` — is also fast, and
it breaks the rule. `.*+` swallows the `=` and never returns it, so nothing
matches and the filter blocks nothing. Fast and wrong looks exactly like fast
and right until something tests it, which is what the corpus is for.

## The rule you have not written yet

Rewriting one regex fixes one regex. The next person to add a rule can make the
same mistake, and the filter will hand them the whole site again.

An evaluator that can spend unbounded time on one input has no upper bound on
its own latency, so give it one:

```
budget_ms = 500
```

Past that, the filter abandons the match and answers anyway. It cannot be done
with a timer in the same thread — `re` holds the GIL for the whole call and a
signal is not delivered until it returns — so the match runs in a forked child
that can be killed. Real WAFs solve it the same way: a step budget in the engine
(PCRE's `match_limit`), a hard time cap per rule, or an engine that cannot
backtrack at all. RE2 and Rust's `regex` are linear by construction, at the cost
of backreferences and lookaround.

What a budget buys is a bounded failure. With one, a pathological rule makes
some requests fail fast. Without one, it makes all requests fail slowly, which
is the same thing as being down.

## What the grader checks

**The corpus verdicts are unchanged.** Every URL in `/root/waf-corpus/block` is
still refused with a 403, and every URL in `/root/waf-corpus/allow` still gets
through. A rule that has been deleted, disabled or broadened into uselessness
fails here.

**The long request is fast and allowed.** 200, in under two seconds. A 500 or a
503 means the budget cut a still-slow rule off rather than the rule getting
faster.

**Six long requests at once do not take the site down.** With a
single-threaded filter, one expensive rule is everybody's expensive rule.

**A rule with the same defect, added afterwards, does not take the site down
either.** The grader appends one to `rules.conf` itself. Nothing about the
rewritten rule helps: only `budget_ms` does.

<details>
<summary>Hint 1 — find out where the time goes</summary>

The filter logs one line per request with the rule it was evaluating and how
long it took:

```
$ journalctl -u waf -f
```

Send the long request and watch. `verdict=allow` after six thousand
milliseconds tells you the request was never going to be blocked.

</details>

<details>
<summary>Hint 2 — the two adjacent stars</summary>

Look at the tail of the rule: `.*(?:.*=.*)`. Two unbounded quantifiers side by
side, and the engine must try every way of dividing the input between them
before it can conclude anything. The second `.*` adds no matches the first has
not already covered.

Test a candidate before installing it — the corpus is right there:

```
$ python3 -c 'import re,time; rx=re.compile(r"YOUR RULE"); \
    t=time.time(); print(bool(rx.search("/api?x=1;a=b")), time.time()-t)'
```

</details>

<details>
<summary>Hint 3 — the second half is not a regex change</summary>

Rewriting the rule fixes the rule that exists. `budget_ms` in
`/etc/waf/waf.conf` is what happens to the next one: the number of milliseconds
a single rule may spend before the filter abandons it and answers anyway. It is
`0`, which means no limit.

</details>

## What actually happened

A rule that blocked the right things was deployed with no bound on what it could
cost, in front of everything, in a filter that answers one request at a time. It
was not compromised and it was not misconfigured. It was asked a question with
an exponential number of answers and it started working through them.

<details>
<summary>Solution</summary>

```bash
$ grep sqli /etc/waf/rules.conf
```

The tail loses its redundant `.*` and the prefix becomes possessive:

```
sqli-inline-assignment	(?:\"|'|\]|\}|\\|\d|(?:nan|infinity|true|false|null|undefined|symbol|math)|\+)++[)]*;?((?:\s|-|~|!|{}|\|\||\+)*.*(?:=.*))
```

Then bound every rule, including the ones not written yet:

```bash
$ cat /etc/waf/waf.conf
budget_ms = 500

$ systemctl restart waf
```

The restart is not part of the fix — the filter re-reads both files when they
change — but it is the only way to abandon a match already in progress.

```bash
$ cat /root/answers/waf.md
failure_mode: catastrophic backtracking
budget_ms: 500
```

</details>
