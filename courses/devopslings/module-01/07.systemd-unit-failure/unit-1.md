---
title: "checkout-api won't start and the exit code tells you nothing"
---

## The situation

Someone moved `checkout-api`'s configuration during a cleanup last night. This
morning the service is down:

```
$ systemctl status checkout-api.service
× checkout-api.service - Checkout API
     Loaded: loaded (/etc/systemd/system/checkout-api.service; enabled)
     Active: failed (Result: exit-code) since Fri 2026-07-31 06:40:11 UTC
    Process: 312 ExecStart=/usr/local/bin/checkout-api (code=exited, status=1/FAILURE)
```

`status=1/FAILURE`. That is systemd telling you the process exited non-zero. It
is not telling you why, because systemd does not know why — only the
application does, and it already said so somewhere you haven't looked yet.

## Your objectives

1. Find the application's own error message.
2. Fix the cause, in a way that survives a restart.
3. Get the service running and enabled.

Objective 2 is the one with teeth. There are at least two ways to make this
service start that will not survive the next reboot, and the check runs a
restart to find out which kind of fix you made.

## What you're being graded on

That the service is active, that it genuinely became ready rather than merely
being started, that its configuration lives on disk, that it comes back after a
`systemctl restart`, and that it is enabled for boot.

<details>
<summary>Hint 1 — status shows you a summary, not the logs</summary>

`systemctl status` prints the last few journal lines, and on a service that has
been retrying they have usually scrolled away. Ask the journal directly:

```
journalctl -u checkout-api.service -n 50 --no-pager
```

Useful variants:

```
journalctl -u checkout-api -b          # this boot only
journalctl -u checkout-api -f          # follow, for watching a fix land
journalctl -u checkout-api -p err      # errors and worse
```

</details>

<details>
<summary>Hint 2 — it won't start again, even before you've fixed anything</summary>

```
$ systemctl start checkout-api
Job for checkout-api.service failed.
$ journalctl -u checkout-api -n 3
... start request repeated too quickly, refusing to start.
```

The unit sets `StartLimitBurst=3` within `StartLimitIntervalSec=30`. After
three failures in that window systemd stops trying, and it will keep refusing
until you clear the rate-limit state:

```
systemctl reset-failed checkout-api.service
```

This catches people constantly. The service looks like it is ignoring your fix
when in fact it is refusing to attempt one.

</details>

<details>
<summary>Hint 3 — where the config is supposed to come from</summary>

Read the unit file:

```
$ systemctl cat checkout-api.service
EnvironmentFile=-/etc/checkout-api/env
```

The leading `-` means "optional" — if the file is missing, systemd starts the
service anyway without complaint. That's why nothing in systemd's own output
mentions a missing file: as far as systemd is concerned, nothing went wrong.

Setting the variable in your shell will not help. Your shell's environment is
not the service's environment.

</details>

<details>
<summary>Solution</summary>

Get the application's own message out of the journal:

```
$ journalctl -u checkout-api.service -n 20 --no-pager
Jul 31 06:40:11 box systemd[1]: Started checkout-api.service - Checkout API.
Jul 31 06:40:11 box checkout-api[312]: FATAL: DATABASE_URL is not set — refusing to start
Jul 31 06:40:11 box systemd[1]: checkout-api.service: Main process exited, code=exited, status=1/FAILURE
Jul 31 06:40:12 box systemd[1]: checkout-api.service: Scheduled restart job, restart counter is at 1.
...
Jul 31 06:40:14 box systemd[1]: checkout-api.service: Start request repeated too quickly.
Jul 31 06:40:14 box systemd[1]: checkout-api.service: Failed with result 'exit-code'.
```

There it is, in the line systemd did *not* summarise: `DATABASE_URL is not
set`.

Find where the unit expects it:

```
$ systemctl cat checkout-api.service | grep Environment
EnvironmentFile=-/etc/checkout-api/env
```

Create it:

```
install -d /etc/checkout-api
echo 'DATABASE_URL=postgres://checkout@db:5432/checkout' > /etc/checkout-api/env
chmod 0640 /etc/checkout-api/env
```

Clear the start-rate-limit state, then start:

```
systemctl reset-failed checkout-api.service
systemctl start checkout-api.service
systemctl enable checkout-api.service
```

```
$ systemctl is-active checkout-api
active
```

### The two fixes that don't count

**Exporting it in your shell.** `export DATABASE_URL=...` then `systemctl
start` does nothing — systemd is PID 1, and it does not inherit your shell's
environment. The service starts with the same empty environment as before.

**`systemctl set-environment` or a `systemd-run` override.** These do work, and
they are gone on the next reboot. The check restarts the service specifically
to separate a fix that lives on disk from one that lives in memory.

### Why the error was hidden

Two mechanisms combined:

`EnvironmentFile=-` made the missing file invisible to systemd. Without the
dash, systemd would have refused to start the unit and said exactly why. The
dash is often correct — plenty of services have genuinely optional overrides —
but it moves the responsibility for noticing onto the application.

`Restart=on-failure` then turned one clear failure into a burst of them, so by
the time a human looked, the useful line had scrolled out of `status` and the
unit had given up. The rate limit exists to stop exactly that loop from running
forever; the cost is that "start request repeated too quickly" is the last
thing you see, and it describes systemd's behaviour rather than the bug.

The habit worth keeping: when a unit fails, read `journalctl -u` before you
read anything else. The exit code tells you *that* it failed. Only the
application can tell you why.

</details>
