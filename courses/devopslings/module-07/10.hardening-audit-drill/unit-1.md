---
title: "the compliance scan failed the reports host, and it will not say which line"
---

## The situation

> The pre-audit compliance scan of the box failed; it reports one finding
> against the `reports` service host. Fix the finding without breaking the
> service.

That is the entire ticket, and it will be the entire ticket every time you run
this lesson — because the finding is drawn at random from five, and each is a
different way a host drifts from the configuration it was signed off with.

You own this box. Its signed-off configuration is written down in
`/etc/reports/baseline.md`, five items, and the scan does nothing cleverer than
diff the box against it. So every fix in this drill is the same sentence: make
the box match the baseline. The skill is finding *which* item no longer
matches, with the audit command that answers for that item, and restoring it
without taking away the thing the item exists to protect.

`reports.service` runs `/opt/reports/reports.py` and answers on
`127.0.0.1:8090`. It reads `/etc/reports/db.key` on every request. The runbook
uses three things, and all three have to work when you are done:

```
$ reports-fetch -s http://127.0.0.1:8090/report      # any user
report ok db=…
$ sudo systemctl restart reports.service             # as reportop
$ ssh -p 22 …                                        # sshd, as ever
```

You cannot memorise the finding. You can memorise the audit.

## Your objectives

- Find the one baseline item the box does not match, and restore it
- Keep the report, the operator's restart and sshd on port 22 working
- Write `/root/answers/triage.md`, three lines:

  ```
  cause:     <what did not match the baseline, in a few words>
  evidence:  <the audit command that showed it>
  detection: <the check that would flag it on every host>
  ```

## What you're being graded on

The grader checks **every** baseline item, not only the one that was seeded,
and checks that what each item protects still works:

- **sudo** — `sudo -l -U reportop` lists exactly
  `/usr/bin/systemctl restart reports.service`, and reportop can still run it.
  Deleting the grant fails: the runbook needs that restart.
- **setuid** — no setuid file on the box that `dpkg -S` cannot name, and
  `reports-fetch` is still there, unchanged, and still fetches a report when
  reportop runs it. Deleting the binary fails.
- **credentials** — `db.key` is `root:reports`, nothing for other users, its
  contents unchanged, and the service can still read it. `chmod 600` as root
  fails: the service runs as `reports`.
- **service** — `reports.service` is enabled, running, configured as
  `User=reports` *and* actually running as `reports`. Stopping or disabling it
  fails; so does removing the `reports` user.
- **listeners** — sshd is running, configured for port 22 only (`sshd -T`),
  and the running daemon listens on 22 only. Stopping sshd fails.
- **the herring stays** — `/usr/bin/passwd` is still setuid root and still
  exactly what the `passwd` package shipped.

And `triage.md`: `cause` must describe the finding that was seeded, `evidence`
must be an audit command that shows that finding, and `detection` must name a
check that would flag it.

<details>
<summary>Hint 1 — one audit command per baseline item</summary>

```
$ cat /etc/reports/baseline.md
$ sudo -l -U reportop                               # 1. sudo
$ find / -xdev -perm -4000 -type f -exec ls -l {} + # 2. setuid
$ dpkg -S <path>                                    #    ...and who installed it
$ stat -c '%U:%G %a %n' /etc/reports/db.key         # 3. credentials
$ systemctl show -p User reports.service            # 4. service user
$ systemctl cat reports.service                     #    ...and every file that sets it
$ ss -ltnp                                          # 5. listeners, live
$ sshd -T | grep '^port '                           #    ...and as configured
```

Go down the list in order. The first item that differs from the baseline is
the finding; the scan says there is only one.

</details>

<details>
<summary>Hint 2 — the newest setuid file is not the finding</summary>

Sort the setuid scan by date and one entry is from the last hour. Recent is not
the same as wrong. The baseline's rule is provenance: a setuid file is allowed
when a package installed it, and `dpkg -S` either names that package or says
nothing owns the path. A package update touches its files; that is what a
recent date on a package-owned binary usually means.

</details>

<details>
<summary>Hint 3 — restore the item, keep what it protects</summary>

Each item exists because something needs it. The narrowest fix is the one that
changes the configuration and nothing else: a sudoers line rewritten to the
exact command, a mode changed with `chmod` on the file that stays, an owner set
to the group the service runs in, a drop-in removed so the unit's own `User=`
applies again, a `Port` line removed and the daemon reloaded. Validate before
you apply — `visudo -c`, `sshd -t` — and remember that systemd and sshd read
their configuration when they start or reload, not when you save the file.

</details>

## What actually happened

| Finding | What drifted | The audit command | The tell |
|---|---|---|---|
| sudo | `/etc/sudoers.d/reports` grants `/usr/bin/systemctl` with no arguments | `sudo -l -U reportop` | the listed command is shorter than the baseline's; a command with no arguments matches every argument list |
| setuid | `/usr/local/bin/reports-fetch` is mode 4755 | `find / -xdev -perm -4000`, then `dpkg -S` | the only setuid file `dpkg -S` cannot name |
| key | `/etc/reports/db.key` is mode 0644 | `stat` | `root:reports 644`: the last digit grants read to every account |
| root | `reports.service.d/10-debug.conf` sets `User=root` | `systemctl show -p User` | `User=root`; `systemctl cat` shows which file said so |
| port | `sshd_config.d/60-reports-debug.conf` adds `Port 2222` | `ss -ltnp`, `sshd -T` | sshd listening on 22 *and* 2222 |

None of the five stops the service. That is why each one survived until an
audit: nothing broke, so nobody looked.

The red herring, every run: `/usr/bin/passwd`, setuid root, the newest entry in
the setuid scan. It belongs there. `dpkg -S /usr/bin/passwd` names the `passwd`
package, and `dpkg --verify passwd` finds its contents as shipped. It is setuid
because users change their own entries in `/etc/shadow` through it. Strip the
bit and every non-root user loses `passwd`.

<details>
<summary>Solution</summary>

Walk the baseline and restore the first item that differs.

```bash
# sudo: exactly the runbook's command
sudo -l -U reportop
echo 'reportop ALL=(root) NOPASSWD: /usr/bin/systemctl restart reports.service' \
  > /etc/sudoers.d/reports
chmod 0440 /etc/sudoers.d/reports && visudo -c

# setuid: remove the bit, keep the program
find / -xdev -perm -4000 -type f -exec dpkg -S {} \; 2>&1 | grep 'no path found'
chmod u-s /usr/local/bin/reports-fetch

# credentials: owner, group, mode
stat -c '%U:%G %a' /etc/reports/db.key
chown root:reports /etc/reports/db.key && chmod 0640 /etc/reports/db.key

# service user: remove the override, let the unit's User= apply
systemctl show -p User reports.service; systemctl cat reports.service
rm /etc/systemd/system/reports.service.d/10-debug.conf
systemctl daemon-reload && systemctl restart reports.service

# listeners: remove the extra Port, validate, reload
ss -ltnp; sshd -T | grep '^port '
rm /etc/ssh/sshd_config.d/60-reports-debug.conf
sshd -t && systemctl reload ssh
```

Then confirm the runbook still works:

```bash
runuser -u reportop -- reports-fetch -s http://127.0.0.1:8090/report
```

And, for example:

```
cause: setuid bit (4755) on /usr/local/bin/reports-fetch, which no package installed
evidence: find / -xdev -perm -4000 -type f, and dpkg -S found no owner
detection: any setuid file from find -perm -4000 that dpkg -S cannot name
```

</details>

## Carrying this forward

- **A baseline turns "is this secure" into "does this match".** The second
  question has one answer per item and a command that gives it.
- **Audit the effective state, not the file you expect.** `sudo -l -U`,
  `systemctl show`, `sshd -T` and `ss` report what is in force, drop-ins and
  includes resolved; the file you opened first may not be the one that won.
- **Restore the item, not the absence of it.** Deleting the grant, the binary,
  the user or the service makes the finding disappear along with the reason the
  item existed.
- **Provenance beats recency.** The newest setuid file on the box was the one
  that belonged there.

Run the lesson again. The finding moves, and the audit does not.
