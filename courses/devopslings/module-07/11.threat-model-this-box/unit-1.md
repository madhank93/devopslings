---
title: "one host, written up properly"
---

## The situation

This box is `invoice-1`. It runs an invoicing web app, takes deploys from CI
over SSH, and backs its database up every night. Its owners wrote a page about
it in `/root/host-notes.md`. The page is accurate. It is also incomplete in one
place that matters.

You are writing the threat model. Not "hackers could steal the data" — that
names nobody and nothing, and no one can act on it. A threat model that is
useful says what is worth taking, how someone gets in, what they can do once
they are in, where the box fails to stop them, and what it would cost to fix.

The template is in `/root/answers/threat-model.md`. One item per line:

```
asset:     something worth protecting, named by its path on this box
entry:     a way in, written tcp/<port>, and who can reach it
boundary:  <principal> -> <principal> via <what crosses>
           principals: internet, deployer, invoice, root
threat:    can=<what the attacker is already able to do> gets=<what that gives them>
missing:   the path of the file where a control is missing, and what is missing
control:   <what you would change> | cost: <what it costs>
```

Nothing on the box needs to change. This is graded on the write-up.

## What you're being graded on

Every claim is checked against the box:

- **assets** — at least two, each named by a path that exists. The payment key
  and the invoice data must both be there.
- **entry points** — every port you name is one that something listens on,
  and both of the box's listening ports are named.
- **boundaries** — written between the four principals. The two that matter on
  this box must both be present.
- **missing** — names the file where the control is missing. Controls that are
  already in place are rejected, with the reason.
- **threats** — at least two. `can=` is a capability tied to this box: a port,
  a user or a file. "hackers" or "attackers" on their own are rejected. One
  threat must end in `gets=root`.
- **controls** — every one has a cost. "none", "free" and "no downside" are
  rejected. One control must close the gap you named.

## Name the capability, not the villain

"An attacker" tells you nothing about what to defend. "Someone who can send
HTTP requests to tcp/8180" tells you exactly: everyone on the internet has
that capability, so every bug in the app is reachable. "Someone who holds the
CI key for deployer" is a different, smaller set of people, with a different
reach.

Writing threats this way does two things. It makes you say where the attacker
starts, which is always an entry point or a foothold you already listed. And it
makes the next question obvious: from there, what can they reach that they
should not?

The same goes for controls. A control that costs nothing does not exist.
Moving a file costs a deploy step. A firewall rule costs a debugging session
the day someone forgets it. Saying the cost out loud is how the control gets
argued for, and how the next person knows what they are trading if they undo
it.

<details>
<summary>Hint 1 — what is on the box</summary>

Start from the box, not from the notes:

```
$ ss -ltnp
$ systemctl cat invoice-web.service
$ ls -l /etc/invoice /var/lib/invoice
$ cat /etc/sudoers.d/* /etc/cron.d/*
$ getent passwd invoice deployer
```

Each listening port is an entry point. Each file a service guards is a
candidate asset. Each place where one user's work is done by another user is a
boundary.

</details>

<details>
<summary>Hint 2 — the boundaries are where users change</summary>

Requests from the internet become code running as `invoice`. A CI key becomes
a shell as `deployer`. `deployer` becomes `root` for one command through sudo.

Is there anywhere else root does work on this box? Look at what root runs on a
schedule, and then look at who owns each file in that chain.

</details>

<details>
<summary>Hint 3 — follow what root executes</summary>

```
$ cat /etc/cron.d/invoice-backup
$ ls -ld /opt/invoice /opt/invoice/bin /opt/invoice/bin/backup.sh
```

Root runs a script every night. Ask who can change that script before 02:15.

</details>

## What is actually on this box

| Thing | Where | Who can touch it |
|---|---|---|
| web app | `invoice-web.service`, tcp/8180 on every interface | anyone the load balancer forwards |
| payment key | `/etc/invoice/payment.env` | `root:invoice 0640`: the app reads it |
| invoice data | `/var/lib/invoice/invoices.db` | `invoice:invoice 0640` in a 0750 dir |
| sshd | tcp/22, key-only, no root login | `deployer`, with the CI key |
| sudo | `/etc/sudoers.d/deployer` | `deployer`: one restart, nothing else |
| nightly backup | `/etc/cron.d/invoice-backup`, as root | runs `/opt/invoice/bin/backup.sh` |
| backup script | `/opt/invoice/bin/backup.sh` | **`invoice:invoice`**, in an `invoice`-owned directory |

Most of the box is done well. The key is readable by the one user that needs
it. sshd refuses passwords and root. The sudo grant is a single command. The
notes say all of this, and all of it checks out.

The gap is the last row. Root runs a script the service user owns. So anyone
who gets code execution as `invoice` — one bug in the web app, which the whole
internet can reach — can rewrite `backup.sh` and wait for 02:15. At that point
they are root. Every other control on the box assumes `invoice` cannot become
root, and nothing enforces that.

This is the pattern to look for on any host: **something more privileged
executing something less privileged can change.** Cron jobs, systemd units,
`ExecStartPre=` scripts, a root-run backup tool reading a config file in the
app's directory. The trust boundary is between the two users, and the control
that belongs on it is ownership: root runs only what root alone can write,
along the whole path.

The tempting wrong answers are the controls that are already present. A
firewall would not help: both ports are meant to be reachable, and the
escalation starts from a foothold, not from the network. TLS ends at the load
balancer by design. The payment key is as tight as its reader allows.

<details>
<summary>Solution</summary>

```
asset: /etc/invoice/payment.env — payment provider key; whoever holds it can charge and refund as us
asset: /var/lib/invoice/invoices.db — every customer's invoices and address
asset: /home/deployer/.ssh/authorized_keys — decides who gets a shell as deployer

entry: tcp/8180 — invoice-web on every interface, reached from the internet through the load balancer
entry: tcp/22 — sshd on every interface, key-only, used by CI as deployer

boundary: internet -> invoice via HTTP requests to tcp/8180
boundary: internet -> deployer via ssh on tcp/22
boundary: deployer -> root via sudo systemctl restart invoice-web.service
boundary: invoice -> root via /opt/invoice/bin/backup.sh, which root runs nightly from cron

threat: can=send crafted HTTP requests to tcp/8180 and so run code as invoice gets=/etc/invoice/payment.env and /var/lib/invoice/invoices.db
threat: can=write files as invoice gets=root, by editing /opt/invoice/bin/backup.sh before 02:15
threat: can=hold the CI private key for deployer gets=a shell on tcp/22 and the ability to restart invoice-web

missing: /opt/invoice/bin/backup.sh — root runs it but invoice owns it and its directory; root executes code the service user can change

control: move the backup script to /usr/local/sbin/invoice-backup, root:root 0755, and point /etc/cron.d/invoice-backup at it | cost: app deploys stop shipping the backup script; changing it needs a root step outside the pipeline
control: AllowUsers deployer in sshd_config | cost: every new operator account needs an sshd change and a reload before it can log in
```

The fix for the gap, if this were your box:

```bash
install -o root -g root -m 0755 /opt/invoice/bin/backup.sh /usr/local/sbin/invoice-backup
sed -i 's|/opt/invoice/bin/backup.sh|/usr/local/sbin/invoice-backup|' /etc/cron.d/invoice-backup
rm /opt/invoice/bin/backup.sh
```

Check the copy before you trust it: it came from a directory `invoice` could
write.

</details>

## Carrying this forward

- **A threat is a capability and a reach.** "Who can do what, from where, to
  get what." If you cannot fill in the first part, you do not yet know which
  control would stop it.
- **Boundaries are where one user's work is done by another.** Network to
  service, CI to shell, shell to sudo, service to root. List them, then check
  each one is actually enforced.
- **Look for the more privileged running the less privileged.** It is the most
  common escalation on a well-kept host, because every individual piece looks
  fine.
- **Every control has a cost, and writing it down is part of the control.** It
  is the argument for applying it, and the warning to whoever wants to undo it.
