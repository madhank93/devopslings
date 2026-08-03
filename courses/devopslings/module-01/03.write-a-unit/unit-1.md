---
title: "a working script and nobody to start it"
---

## The situation

`/usr/local/bin/stock-feed` works. Somebody wrote it, tested it by running it,
and put it on the box. That is where it stopped.

```
$ /usr/local/bin/stock-feed
stock-feed: started
^C
```

It does not start at boot. When it exits, nothing brings it back. And it has an
opinion about what has to be running first:

```
$ systemctl stop stock-cache.service
$ /usr/local/bin/stock-feed
stock-feed: stock-cache is not ready — refusing to start
$ echo $?
69
```

None of those three problems can be solved inside the script. They are the
init system's job, and this is the file that asks for them.

## Your objective

Write `/etc/systemd/system/stock-feed.service` so that stock-feed:

1. runs `/usr/local/bin/stock-feed`
2. starts automatically at boot
3. is restarted automatically whenever it exits — **including when it exits
   successfully**
4. is never started before `stock-cache.service` has finished

Then enable and start it.

## What you're being graded on

The behaviour, established by doing it. The check kills the process and waits
for it to come back, and it restarts the whole pair from cold to see whether
your unit waits for the cache or merely retries until the cache happens to be
ready. Those look identical once the dust settles and they are not the same
thing.

<details>
<summary>Hint 1 — the smallest unit that runs at all</summary>

```ini
[Unit]
Description=Stock price feed

[Service]
ExecStart=/usr/local/bin/stock-feed
```

Save it, then:

```
$ systemctl daemon-reload      # systemd does not watch the directory
$ systemctl start stock-feed
$ systemctl status stock-feed
```

`daemon-reload` after every edit. A surprising amount of time gets lost to
editing a unit, restarting it, and watching the old version run.

That covers requirement 1. It covers none of the others.

</details>

<details>
<summary>Hint 2 — "starts at boot" is a symlink, and it needs somewhere to point</summary>

```
$ systemctl enable stock-feed
The unit files have no installation config (WantedBy=, RequiredBy=, Also=,
Alias= settings in the [Install] section)
```

`enable` does exactly one thing: it creates a symlink from a target's `.wants`
directory to your unit. With no `[Install]` section there is nothing to tell it
which target, so there is no symlink, and nothing starts your service at boot.

```ini
[Install]
WantedBy=multi-user.target
```

`multi-user.target` is the normal "system is up and running services" state.

`is-enabled` and `is-active` answer different questions — a unit can be running
now and still absent after a reboot, which is the failure mode that shows up
weeks later during unrelated maintenance.

</details>

<details>
<summary>Hint 3 — Restart=, and the option that looks right</summary>

```ini
Restart=on-failure
```

That is the common choice, and it is wrong for requirement 3. `on-failure`
means non-zero exits, signals, timeouts and watchdog failures — but a process
that exits **0** is treated as having finished on purpose, and systemd leaves
it stopped.

`stock-feed` traps `SIGTERM` and exits 0. So under `on-failure`, anything that
politely asks it to stop kills it permanently.

```ini
Restart=always
RestartSec=1
```

`always` covers both. `RestartSec` is the pause between attempts; the default
100 ms is fine, and a slightly longer one is easier to watch.

Try it: get the PID with `systemctl show -p MainPID --value stock-feed`, send
it a plain `kill -TERM`, and see whether it comes back. Note that `systemctl
stop` is *not* the same test — that is an instruction to stay stopped, and no
`Restart=` setting overrides it.

</details>

<details>
<summary>Hint 4 — ordering, and why Restart= is not ordering</summary>

```ini
After=stock-cache.service
```

`After=` is purely about sequence: *if both are being started, do not start
this one until that one is up*. It does not pull the other unit in. If you want
starting the feed to also start the cache, you need a dependency as well:

```ini
Wants=stock-cache.service      # start it too; carry on if it fails
Requires=stock-cache.service   # start it too; fail if it fails
```

`Wants=` is the right default. `Requires=` couples the two so tightly that the
cache failing takes the feed down with it, which is rarely what you want and is
its own outage.

Now the part worth understanding. `stock-cache.service` is:

```ini
Type=oneshot
RemainAfterExit=yes
```

For a `oneshot`, "started" means **finished** — so `After=` genuinely waits the
four seconds. Had it been `Type=simple`, systemd would consider it started the
instant it forked, `After=` would wait for essentially nothing, and your feed
would still lose the race. Ordering is only as meaningful as the dependency's
`Type=` makes it.

And this is why `Restart=` is not a substitute: with no `After=`, the feed
starts immediately, fails, and retries until the cache happens to be ready.
It ends up running, so it looks fixed. The check reads the journal for that
first failed attempt.

</details>

<details>
<summary>Solution</summary>

```ini
[Unit]
Description=Stock price feed
Wants=stock-cache.service
After=stock-cache.service

[Service]
ExecStart=/usr/local/bin/stock-feed
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

```
$ systemctl daemon-reload
$ systemctl enable --now stock-feed.service
```

### Why this is a lesson at all

Every other exercise in this module hands you something broken. This one hands
you something that works and asks you to make it survive contact with a
machine that reboots, kills processes, and starts things in an order you did
not choose.

The four settings map to four different failures, and each one has a plausible
wrong answer that a checklist would accept:

1. **`ExecStart=`** — the only part most people write. Fine.
2. **`[Install]` + `enable`** — omit it and everything works perfectly until
   the first reboot, which may be months away and will not be attributed to
   this.
3. **`Restart=always` vs `on-failure`** — `on-failure` is the more thoughtful-
   looking choice and it silently excludes clean exits. A service that shuts
   down tidily and never returns is a genuinely confusing outage, because every
   log line says it stopped normally.
4. **`After=` vs retrying** — a retry loop reaches the same end state and hides
   a real ordering bug. It works on a fast box and fails on a slow one, or on
   the day the dependency takes six seconds instead of four. "It comes up
   eventually" and "it comes up correctly" are different properties, and only
   one of them holds under load.

The general shape: **the init system is where you declare what has to be true,
rather than where you write code that copes with it not being true.**

</details>
