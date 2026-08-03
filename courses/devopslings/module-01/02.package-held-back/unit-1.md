---
title: "the security update that apt quietly declined to install"
---

## The situation

`ledger-tools 1.1` fixes CVE-2026-3312. It has been in the archive for three
weeks. Unattended upgrades run nightly, exit 0, and report success.

```
$ ledger-tools
ledger-tools 1.0

$ apt-get upgrade
Reading package lists... Done
Building dependency tree... Done
Calculating upgrade... Done
The following packages have been kept back:
  ledger-tools
0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
```

Exit status 0. Nothing failed. The fleet dashboard says "patched", because the
thing it measures is whether the upgrade job succeeded, and it did.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/reason` | one of `hold`, `phasing`, `newdeps`, `pin` |

Then get `ledger-tools` onto 1.1, and leave no held packages behind.

The four things that make apt decline an upgrade it can see:

| | means | fixed by |
|---|---|---|
| `hold` | someone marked this package held | `apt-mark unhold` |
| `phasing` | a staged rollout; you are not in this wave yet | waiting, or overriding the phase |
| `newdeps` | the new version needs packages `upgrade` may not add | `apt full-upgrade` |
| `pin` | `/etc/apt/preferences.d` prefers a different version | editing the preference |

## What you're being graded on

Naming the mechanism, and the outcome: version 1.1 actually installed, the
binary itself reporting 1.1, and `apt-mark showhold` empty.

<details>
<summary>Hint 1 — "kept back" is apt being explicit, not apt being vague</summary>

The wording is a real signal and the four causes say different things:

- **kept back** — apt wants to upgrade it and something is stopping it.
- **deferred due to phasing** — this box is not in the rollout wave yet.
- **not upgraded** in the trailing count, with no per-package list — usually
  new dependencies.

You have "kept back", by name, with the package listed. That narrows it
immediately — and the nightly job printed this line every night for three
weeks, into a log nobody reads, while exiting 0.

</details>

<details>
<summary>Hint 2 — ask apt what it thinks it wants</summary>

```
$ apt-cache policy ledger-tools
ledger-tools:
  Installed: 1.0
  Candidate: 1.1
  Version table:
     1.1 500
        500 file:/srv/localrepo ./ Packages
 *** 1.0 500
        500 file:/srv/localrepo ./ Packages
        100 /var/lib/dpkg/status
```

Read the **Candidate** line carefully. It is 1.1.

That single fact eliminates `pin`: a pin works by changing which version apt
considers the candidate. If a preference file were demoting 1.1, the candidate
would be 1.0 and there would be a priority other than 500 next to it. apt wants
1.1 and is still not installing it, so whatever is blocking it sits somewhere
else entirely.

</details>

<details>
<summary>Hint 3 — the list nobody checks</summary>

```
$ apt-mark showhold
```

A hold is a flag in the dpkg database that says "never change this package's
version, no matter what". It is not in a config file you would find by grepping
`/etc/apt`, it survives reboots and reinstalls of apt itself, and nothing
prints it unless you ask.

It is the correct tool during an incident — freeze a package while you work out
whether it caused the outage — and it is almost always still set six months
later, because the person who set it moved on and it is invisible.

</details>

<details>
<summary>Solution</summary>

```
$ apt-mark showhold
ledger-tools

$ echo hold > /root/answers/reason

$ apt-mark unhold ledger-tools
Canceled hold on ledger-tools.

$ apt-get install --only-upgrade ledger-tools
$ ledger-tools
ledger-tools 1.1

$ apt-mark showhold
$
```

### Why this is a lesson at all

This is the first `intro` exercise where the machine was not broken. Everything
worked exactly as designed: apt honoured a hold, said so on stdout, and exited
0. The failure was that "the upgrade job succeeded" and "the software is
patched" are different claims, and the monitoring measured the first one.

Three things worth carrying:

1. **Exit 0 is not evidence of the outcome you wanted.** It means the program
   finished the job it thought it had. `apt upgrade` regards declining to
   upgrade a held package as a complete success, and it is right to. If you
   want to know whether a version is installed, check the version.

2. **Read the whole output, particularly the boring line.** "The following
   packages have been kept back" is the entire diagnosis, printed nightly for
   three weeks. Automation that only checks exit status throws it away, which
   is the actual bug here and is worth fixing in the job as well as on the box.

3. **State set during an incident outlives the incident.** A hold, a firewall
   rule, a scaled-down replica count, a disabled alert. All of them are the
   right call at the time and all of them are invisible afterwards. `apt-mark
   showhold` costs nothing and belongs in whatever you use to audit a fleet —
   the same way `systemctl list-unit-files --state=masked` does.

</details>
