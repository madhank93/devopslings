---
title: "the deploy went out and the browser still has yesterday"
---

## The situation

Build 2 is live on the origin:

```
$ curl -s http://172.32.0.11:8080/asset.js
console.log('build 2');
```

Through the edge, at the fingerprinted URL the new page asks for:

```
$ curl -s 'http://127.0.0.1/asset.js?v=2'
console.log('build 1');
```

Look at what that means before looking at any configuration. `?v=2` is a URL
that has *never been requested before* — that is the entire point of putting a
build number in it. A cache cannot have a stale copy of a URL it has never
seen. Unless, of course, it does not think that is a different URL.

And a second report, from support: some users are seeing someone else's profile
page.

```
$ curl -s -H 'X-User: alice' http://127.0.0.1/profile
profile: alice
$ curl -s -H 'X-User: bob' http://127.0.0.1/profile
profile: alice
```

Two symptoms, two lines of configuration, and both lines were added on purpose
by someone who had a reason.

## Line one: what makes a cache entry different

```nginx
proxy_cache_key "$scheme$request_method$host$uri";
```

`$uri` in nginx is **the path with the query string removed**, after any
internal rewrites. `$request_uri` is the original request line — path *and*
query.

So with that key, these are all the same cache entry:

```
/asset.js
/asset.js?v=1
/asset.js?v=2
/asset.js?v=whatever
```

Every cache-busting scheme in existence — fingerprinted assets, `?v=`, a build
hash in the query — works by changing the URL so the cache treats it as new
content. A key that drops the query string turns all of that off, silently. The
deploy pipeline is doing its job perfectly and the edge is discarding the one
piece of information it was sending.

`$request_uri` restores it:

```nginx
proxy_cache_key "$scheme$request_method$host$request_uri";
```

Two notes worth having:

- The default nginx key is `$scheme$proxy_host$request_uri`, which is correct.
  Every instance of this bug is somebody having *written* a custom key — usually
  to normalise something — and dropping a component while doing it.
- Fingerprinting in the *path* (`/asset.a1b2c3.js`) rather than the query is
  more robust for exactly this reason: it cannot be normalised away by a key,
  and intermediary caches that ignore query strings still behave.

## Line two: Vary is the origin telling you one copy is not enough

```nginx
proxy_ignore_headers Vary;
```

The origin sends:

```
$ curl -si http://172.32.0.11:8080/profile | grep -i vary
Vary: X-User
```

`Vary` is the response saying: *this body depends on that request header; if you
store me, store one copy per distinct value of it.* nginx obeys it by default.
`proxy_ignore_headers Vary` tells nginx to store a single copy and hand it to
everyone.

That line gets added because `Vary` genuinely can wreck a hit ratio. `Vary:
User-Agent` — which some frameworks emit by default — means a separate cached
copy per browser version string, which is thousands of copies of the same bytes
and effectively no cache at all. Someone hits that, finds `proxy_ignore_headers
Vary` on a forum, and it works. Then a per-user response appears on the same
server, and one user's page gets served to another.

The honest ways to deal with an expensive `Vary`:

- **Do not cache responses that vary per user.** `proxy_no_cache` /
  `proxy_cache_bypass` on a session cookie is the normal answer for logged-in
  traffic.
- **Normalise the varying dimension** before it reaches the cache — map dozens
  of `Accept-Encoding` spellings down to `gzip` / `br` / none, rather than
  ignoring the header.
- **Ignore `Vary` only for a specific header you have decided does not matter**,
  in a location that only serves responses where that is true.

Ignoring it globally, on a server that also serves per-user pages, is a data
leak with a performance justification.

## Fixing the config does not fix what is already stored

This one catches people. A cache entry stored while `Vary` was ignored is on
disk *without* the variance recorded. Changing the configuration changes what
happens to the next miss; it does not rewrite what is already there. The
poisoned entries keep being served until they expire.

So the remediation is two steps: correct the configuration, then remove the
entries that were stored under the wrong rules.

```bash
$ find /var/cache/nginx/edge -type f -delete
```

Which is *not* the same as the thing this lesson is against. Purging a
corrupted cache once, as remediation, is correct. Purging the whole cache on
every deploy — the usual reflex when a deploy shows stale content — treats the
symptom, throws away every entry that was fine, and puts the entire origin load
on the first minute after every release. The reason the deploy did not
invalidate correctly is a bug, and purging hides it until the next one.

## Your objective

1. A newly deployed build is served immediately at its own URL. Graded by
   deploying a build, letting the edge cache it, deploying another, and asking
   for the new one.
2. No user is served another user's profile.
3. **The cache still caches.** Twenty identical requests, and the origin must
   see no more than three of them.

Then `/root/answers/cache.md`:

```
key_missing: <one word>
vary_header: <header name>
```

## What you're being graded on

The third requirement is the one that makes this a cache lesson rather than a
correctness lesson. Every one of these "fixes" the first two symptoms:

- `proxy_cache off`
- `proxy_no_cache 1`
- putting `$request_id` — or any unique value — in the cache key
- `proxy_cache_valid 200 0s`

And every one of them hands 100% of the traffic to the origin. The origin
records what it receives, so this is measured directly rather than inferred from
a header.

<details>
<summary>Hint 1 — is it even a different URL to the cache?</summary>

```
$ curl -si 'http://127.0.0.1/asset.js?v=2' | grep -i x-cache
X-Cache-Status: HIT
```

A HIT on a URL nobody has ever requested is the whole answer. Something is
making two different URLs into one key. Read the key, and look up what `$uri`
contains.

</details>

<details>
<summary>Hint 2 — ask the origin what it said</summary>

```
$ curl -si http://172.32.0.11:8080/profile | grep -i vary
```

The origin is telling the cache how to store that response. Something in the
edge configuration is deciding not to listen.

</details>

<details>
<summary>Hint 3 — the entries already on disk</summary>

If both configuration lines are right and bob still gets alice's page, the entry
that is being served was stored under the old rules. It will not correct itself
before it expires.

```
$ find /var/cache/nginx/edge -type f | head
```

</details>

## What actually happened

```nginx
proxy_cache_key "$scheme$request_method$host$uri";   # no query string
proxy_ignore_headers Vary;                            # one copy for everyone
```

The first turned every fingerprinted URL into the same cache entry, so deploys
were invisible until the entry expired. The second stored one copy of a
per-user response.

Neither is a typo. Both are lines somebody added deliberately — one to normalise
keys, one to raise a hit ratio — and both were correct for the response they
were thinking about at the time and wrong for the next one that came along.

<details>
<summary>Solution</summary>

```nginx
location / {
    proxy_pass http://172.32.0.11:8080;
    proxy_cache edge;

    proxy_cache_key "$scheme$request_method$host$request_uri";

    proxy_cache_valid 200 60s;
    add_header X-Cache-Status $upstream_cache_status always;
}
```

```bash
$ nginx -t && systemctl reload nginx
$ find /var/cache/nginx/edge -type f -delete    # the poisoned entries, once
$ printf 'key_missing: query\nvary_header: X-User\n' > /root/answers/cache.md
```

</details>

## Carrying this forward

- **The cache key is the definition of "the same request".** Anything you leave
  out is something you are declaring irrelevant to the response — for every
  response on that server.
- **Do not write a custom key unless you can say what you are removing and
  why.** The default includes the full request URI, and most custom keys exist
  to normalise one thing and drop three by accident.
- **`Vary` is the origin's instruction, not a suggestion.** Ignoring it is
  choosing to serve one user's response to another; the only safe version of
  that choice is scoped to one header, in one location, deliberately.
- **A cache fix has two halves: the rule, and the entries stored under the old
  rule.** Configuration is not retroactive.
- **"Purge on every deploy" is a workaround wearing a fix's clothes.** It is a
  thundering herd against the origin every release, and it hides the
  invalidation bug that will still be there next time.
