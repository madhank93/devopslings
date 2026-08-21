---
title: "turn off password logins on a box you are sitting inside"
---

## The situation

Security wants SSH password authentication off by Friday. The change itself is
one line. The reason people are frightened of it is that the box you are
changing is the box you are logged into, and the failure mode is not an error
message — it is a machine nobody can reach any more.

This box is `172.31.0.10`. It takes passwords and nothing else:

```
deploy / deploy-2026
```

There is no `authorized_keys` anywhere on it. The ops workstation is the other
box on this network, `172.31.0.11`, and its key pair is sitting in `/lab`, which
both machines can see.

There is also a session already open — `ops-session.service`, writing a
timestamp to `/run/ops-session` every two seconds. It stands in for the terminal
you are reading this in.

## The order is the whole job

Every safe version of this change is the same three steps in the same order:

1. **Make the new way in work.** Install the key. Log in with it, from somewhere
   else, and see a shell.
2. **Take the old way out.** Turn off password authentication.
3. **Prove it, in a new session**, while the old one is still open.

Doing 2 before 1 is how boxes are lost. And the loss is quiet: everything keeps
working, because everything currently connected stays connected. The bill
arrives at the next reconnect, which might be tomorrow, and might be during an
incident.

The rule this comes down to: **never close the door you are standing in until
you have opened another one and walked through it.**

## What sshd is actually running

Here is the part that catches careful people. The obvious move is:

```
$ sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
$ systemctl reload ssh
```

and it does nothing at all:

```
$ sshd -T | grep -i passwordauthentication
passwordauthentication yes
```

Look at the first line of the config you just edited:

```
$ head -1 /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf

$ grep -ri passwordauthentication /etc/ssh/
/etc/ssh/sshd_config:PasswordAuthentication no
/etc/ssh/sshd_config.d/50-cloud-init.conf:PasswordAuthentication yes
```

**`sshd_config` is first-match-wins.** For most keywords, the first value sshd
reads is the one it keeps, and every later mention is ignored. Debian and Ubuntu
put the `Include` on line one, so anything in `sshd_config.d/` is read *before*
the whole main file — which means a drop-in silently outranks every line you can
see in the file you opened.

Most config formats are the other way round, which is exactly why this one
surprises people, and why `50-cloud-init.conf` re-enabling password auth is a
genuinely common production outage in reverse: the setting everyone believes is
off has been on for months.

**`sshd -T` is the source of truth.** It prints the effective configuration — the
merged result, every default filled in, in the words sshd itself uses. Anything
you conclude by reading a file is a guess about what sshd did with it.

```
$ sshd -T | grep -iE 'passwordauth|permitroot|pubkeyauth'
```

Related, worth knowing before you write your own drop-in: `Match` blocks apply
until the next `Match` or end of file, and inside one the first-match rule
applies again. And `KbdInteractiveAuthentication` is a second door — PAM's
challenge-response path, which on many boxes also ends up asking for a password.
Turning off `PasswordAuthentication` and leaving that on is a half-done job.

## reload, restart, and what actually ends a session

```
$ sshd -t              # parse the config, say nothing if it is valid
$ systemctl reload ssh # SIGHUP: re-read the config, keep listening
```

`sshd -t` before either verb. It is the difference between "that config is
wrong" and "sshd is not running and I cannot get back in to fix it".

What each one does to the session you are in:

- **reload** sends SIGHUP. The listener re-execs; every established connection is
  its own process and carries on. Nothing you are doing is interrupted.
- **restart** stops and starts the unit. On Debian this is survivable too,
  because `ssh.service` ships `KillMode=process` — systemd kills the listener and
  deliberately leaves the per-session children alone:

  ```
  $ systemctl show ssh -p KillMode --value
  process
  ```

  Do not rely on that on a box you have not checked. A unit with the default
  `KillMode=control-group` takes every session with it, and people do edit units.
- **`pkill sshd`** ends everything, always. There is no version of this change
  that needs it.

The real lockout risk is not the verb. It is applying a config sshd will not
start with, on a box where your key does not work yet — then the daemon is down,
your session is the last one, and it is one dropped connection from over.

## Your objective

Four things.

1. Make `deploy` reachable **by key from the ops workstation**, using the key
   pair already in `/lab`.
2. Turn password authentication off — as `sshd -T` sees it, not as the file you
   edited claims.
3. Do it without dropping the open session and without leaving sshd refusing to
   start.
4. Write `/root/answers/ssh.md`, exactly two lines:

   ```
   overriding_file: <the file whose setting beat the one you edited>
   first_or_last_wins: <first or last>
   ```

## What you're being graded on

Grading runs **from the other box**, because a key login that only works from the
machine you are already on proves nothing. It checks that `deploy` gets in by
key, that sshd offers no password method to anyone, that `sshd -T` agrees, that
the session which was open before you started is still writing, and both
answers.

<details>
<summary>Hint 1 — installing a key, and the permissions sshd insists on</summary>

```
$ install -d -m 700 /home/deploy/.ssh
$ cat /lab/ops_key.pub >> /home/deploy/.ssh/authorized_keys
$ chmod 600 /home/deploy/.ssh/authorized_keys
$ chown -R deploy:deploy /home/deploy/.ssh
```

sshd refuses to read a key file that is group- or world-writable, or one in a
directory that is, and it refuses **silently** from the client's point of view —
you get `Permission denied (publickey)` either way. The reason is in the
server's journal:

```
$ journalctl -u ssh -n 20
```

Then test it from the other box before you change anything else:

```
$ ssh -i /lab/ops_key deploy@172.31.0.10 id -un
```

</details>

<details>
<summary>Hint 2 — ask the server what it will accept</summary>

```
$ ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no deploy@172.31.0.10
deploy@172.31.0.10: Permission denied (publickey,password).
```

The list in the brackets is the server's own statement of the methods it is
willing to try for that user. When the change has worked it reads
`(publickey)`, and nothing you did on the client side can fake that.

</details>

<details>
<summary>Hint 3 — where the setting is really coming from</summary>

```
$ sshd -T | grep -i passwordauthentication
$ grep -ri passwordauthentication /etc/ssh/
$ head -1 /etc/ssh/sshd_config
```

If those first two disagree, the third explains why. Fix the file that is
actually winning — editing it, or emptying it — rather than adding another one
after it, because a new file will not be read first either.

</details>

## What actually happened

Two things, and only one of them was on purpose.

The box had no key access at all, so password authentication was the only door
in — turning it off first would have been the whole outage in one command.

And `/etc/ssh/sshd_config.d/50-cloud-init.conf` said `PasswordAuthentication
yes`, ahead of the main config in read order. That file is not a contrivance:
cloud-init writes exactly that on most cloud images, and the file's own header
tells you not to edit it by hand, which is why people edit `sshd_config`
instead, restart, see no error, and believe they are done.

<details>
<summary>Solution</summary>

Key first, and prove it from the other box:

```
$ install -d -m 700 /home/deploy/.ssh
$ cat /lab/ops_key.pub >> /home/deploy/.ssh/authorized_keys
$ chmod 600 /home/deploy/.ssh/authorized_keys
$ chown -R deploy:deploy /home/deploy/.ssh

peer$ ssh -i /lab/ops_key deploy@172.31.0.10 id -un
deploy
```

Then close the other door — in the file that is winning:

```
$ cat > /etc/ssh/sshd_config.d/50-cloud-init.conf <<'CONF'
# Written by the image build. Do not edit by hand.
PasswordAuthentication no
CONF
$ sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

$ sshd -t && systemctl reload ssh
$ sshd -T | grep -i passwordauthentication
passwordauthentication no
```

Both files, so that removing the drop-in later does not quietly re-open it.

And check from outside, in a new session, while the old one is still up:

```
peer$ ssh -o PreferredAuthentications=none deploy@172.31.0.10
deploy@172.31.0.10: Permission denied (publickey).
```

```
overriding_file: /etc/ssh/sshd_config.d/50-cloud-init.conf
first_or_last_wins: first
```

</details>

## Carrying this forward

- **Open the new door before closing the old one**, and walk through it from
  another machine. A key you have not used is not a key you have.
- **`sshd -T` is the config.** Files are input. When they disagree with the
  running daemon, the daemon is right.
- **`sshd_config` is first-match-wins, and the `Include` is on line one.** The
  drop-in directory outranks everything you can see below it.
- **`sshd -t` before every apply**, and prefer `reload` to `restart`. Neither
  ends your session on a stock Debian box; a broken config does end your future.
- **Keep a second session open** for the whole change. It costs a terminal and
  it is the difference between a mistake and an incident.
- **`PasswordAuthentication no` is not the end of it.** Check
  `KbdInteractiveAuthentication`, `PermitRootLogin`, and any `Match` block that
  re-opens what you just closed.

The next lesson leaves the login alone and goes after mail: SPF, DKIM and DMARC,
where the records live in DNS, the failure is silent, and the only symptom is
that your mail is landing in spam.
