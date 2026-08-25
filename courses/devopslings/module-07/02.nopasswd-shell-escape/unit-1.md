---
title: "the NOPASSWD line that reads like log access and spends like a root shell"
---

## The situation

deploybot can run two things as root without a password:

```
$ sudo -u deploybot sudo -n -l
User deploybot may run the following commands on box:
    (root) NOPASSWD: /usr/bin/awk
    (root) NOPASSWD: /usr/bin/systemctl restart app.service
```

The second line is exactly what it looks like: restart one named service,
nothing else. The first line looks like the smaller privilege of the two — it
is only `awk`, a text tool, presumably for log reports.

It is the whole machine:

```
$ sudo -u deploybot sudo -n /usr/bin/awk 'BEGIN{system("id")}'
uid=0(root) gid=0(root) groups=0(root)
```

No password, no exploit, no second step. One command, and deploybot is root.

## Why awk is a root shell

`sudo` restricts *which command* runs, not what that command then does. awk is a
programming language: `system("...")` runs any shell command, and because sudo
started awk as root, that command runs as root too. `BEGIN{system("id")}` is a
complete awk program that never touches a file — it just runs `id`. Swap `id`
for `bash` and it is an interactive root shell.

The sudoers line grants "run awk as root". Since awk runs whatever program it is
given, that is identical to granting "run anything as root". The narrowing that
the line appears to express — a text tool, not a shell — does not exist. sudo
never promised it.

This is not specific to awk. `find` has `-exec`, `vi` and `less` have `!cmd`,
`tar` has `--to-command`, `env` runs its argument, `python`/`perl`/`sed` all
take a program. The project that catalogues these is GTFOBins, and the entries
are long. The rule that falls out of it is short:

> A NOPASSWD grant on any program that can run another program is a NOPASSWD
> grant on everything.

## Constraining the arguments does not save it

The instinct is to pin awk down:

```
deploybot ALL=(root) NOPASSWD: /usr/bin/awk -f /opt/report.awk
```

Now `sudo awk 'BEGIN{system(...)}'` no longer matches the rule, so that exact
escape is blocked. But sudo's argument matching is a string match, and awk has
more than one way in — a different flag, a program passed a different way, an
input file whose contents awk is told to execute. Every pinned form is a new
puzzle, and the binary is on the attacker's side of it: its entire job is to run
programs.

So the fix is not a better pattern. It is to stop granting the binary at all.

## What the grant was actually for

awk was in there for a reason — someone needed deploybot to produce reports from
`/var/log/app.log`. Work out the privilege that reason truly requires, and it is
smaller than it looks:

**Reading a log file does not need root.** `/var/log/app.log` is `0600
root:root` only because nobody set it up to be shared. Give deploybot read
access the ordinary way — a group on the file, and deploybot in the group — and
the entire reason for the awk grant is gone. deploybot runs awk over the log as
*itself*, with no sudo in the picture:

```
$ sudo groupadd logreaders
$ sudo usermod -aG logreaders deploybot
$ sudo chgrp logreaders /var/log/app.log
$ sudo chmod 0640 /var/log/app.log
```

Now deploybot reads and reports on the log with no elevated privilege at all,
and the sudoers file keeps only the grant that genuinely needs root:

```
deploybot ALL=(root) NOPASSWD: /usr/bin/systemctl restart app.service
```

That line is safe for the reason the awk line was not: `systemctl restart
app.service`, with the service named, does one thing. It is not a language, it
takes no program, and the argument is fixed. sudo's promise and the actual
privilege are the same size.

## The habit

When you read a sudoers line, ask what the granted binary *can be made to do*,
not what it is named for. A tool's name is marketing; its capabilities are the
grant. Anything that runs a program, opens a shell, writes an arbitrary file, or
loads code is a full-privilege grant no matter how the line is dressed. And when
a grant is too broad, look for the smaller privilege underneath it — often, as
here, the task did not need root in the first place.

<details>
<summary>Hint 1 — which of the two binaries runs a program you choose</summary>

`systemctl restart app.service` does one fixed thing. The other command is a
language interpreter. Ask which one can be told to run `id`, or `bash`.

</details>

<details>
<summary>Hint 2 — do not try to constrain it</summary>

Pinning awk's arguments moves the hole, it does not close it. The line has to
go. The question that unlocks the fix is: what did deploybot actually need awk
*for*, and does that need root?

</details>

<details>
<summary>Hint 3 — the log</summary>

deploybot ran awk over `/var/log/app.log`. Reading a file is a file-permission
question, not a sudo question. Make the log readable by a group deploybot is in,
and the awk grant has no remaining purpose.

```
$ sudo -u deploybot test -r /var/log/app.log && echo readable
```

</details>

## Checking yourself

The one command that proves the hole is closed is the same one that opened it:

```
$ sudo -u deploybot sudo -n /usr/bin/awk 'BEGIN{system("id")}'
sudo: a password is required
```

`a password is required` — not `uid=0` — means awk is no longer a passwordless
grant. Then confirm the two things that had to survive:

```
$ sudo -u deploybot sudo -n systemctl restart app.service && echo restart ok
$ sudo -u deploybot cat /var/log/app.log
```

<details>
<summary>Solution</summary>

```bash
# The log-reading need does not require root — grant it by group.
sudo groupadd logreaders
sudo usermod -aG logreaders deploybot
sudo chgrp logreaders /var/log/app.log
sudo chmod 0640 /var/log/app.log

# Drop the awk grant entirely; keep only the pinned, single-purpose one.
sudo tee /etc/sudoers.d/deploybot >/dev/null <<'SUDO'
deploybot ALL=(root) NOPASSWD: /usr/bin/systemctl restart app.service
SUDO
sudo visudo -cf /etc/sudoers.d/deploybot
```

```
dangerous_binary: awk
mechanism: arbitrary command execution
```

</details>
