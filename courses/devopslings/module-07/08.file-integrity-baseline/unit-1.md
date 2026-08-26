---
title: "the integrity monitor that cried deploy"
---

## The situation

A file-integrity monitor watches this box: it took a baseline of file hashes,
and `fim-check` reports anything that no longer matches. This morning:

```
$ fim-check
CHANGED  /etc/sudoers.d/appdeploy
CHANGED  /srv/app/current/asset1.js
CHANGED  /srv/app/current/asset2.js
...  (thirteen more) ...
```

Sixteen changes. Fifteen of them are `/srv/app/current/*` — today's release,
rewriting the application. Entirely expected, and it will happen again on the
next deploy, and the one after that. The sixteenth is not:

```
$ cat /etc/sudoers.d/appdeploy
appdeploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart app.service
appdeploy ALL=(ALL) NOPASSWD: ALL          # <- this line
```

Someone gave the `appdeploy` account passwordless root over the entire system.
It is one line in a sixteen-line report that looks like sixteen lines of the
same thing, and on a box that deploys ten times a day nobody reads it. The
monitor did its job perfectly and told no one anything.

## A baseline is only as good as its scope

File-integrity monitoring rests on one assumption: the things it watches are
supposed to stay the same, so any change is worth a look. That assumption is the
whole value. A changed hash means "something you did not expect happened here" —
which is actionable precisely because you expected nothing to happen.

Point it at a directory that changes on every deploy and the assumption breaks.
`/srv/app/current` is *built* to change; that is what a release is. Watching it
does not detect anything — it generates a guaranteed stream of expected changes
that a real one has to hide in. You have not added coverage, you have added
noise, and noise is where intrusions live.

The fix is not a smarter diff or a longer report. It is scope: watch what is
supposed to be stable, and do not watch what is supposed to move.

```
$ cat /etc/fim/watch.list
/etc/app.conf
/usr/local/bin/app-helper
/etc/sudoers.d/appdeploy
/srv/app/current          <- remove this
```

Drop the deploy directory. The system config, the helper binary, and the sudoers
drop-in stay — those are the things that should never change without someone
knowing. Re-run the check:

```
$ fim-check
CHANGED  /etc/sudoers.d/appdeploy
```

One line. The intrusion, alone, obvious.

## Whose job is the app directory, then?

Removing `/srv/app/current` from the host monitor is not ignoring it — it is
putting its integrity where it belongs. The application's files are verified by
the thing that produces them: a build pipeline that signs its releases, a
deploy that checks a manifest of expected hashes before it goes live, an
artifact store that records what shipped. That system knows what `build-101` is
*supposed* to contain; the host FIM does not and cannot, because to the host
every deploy is just a pile of files that changed.

Two different questions, two different tools: "did the release deploy what the
pipeline built" is the pipeline's, and "did anything change on this host that no
deploy accounts for" is the FIM's. Conflating them is what produced the
sixteen-line report. Separated, each is answerable.

## The other wrong fix

There is a tempting shortcut that makes the report clean and the box less safe:
re-take the baseline over the current state.

```
$ sha256sum -c ... # regenerate baseline from what's on disk now
```

Now `fim-check` reports nothing, because the current state *is* the baseline —
including the `NOPASSWD: ALL` line, now recorded as known-good. You have not
resolved the alert, you have promoted the intrusion to policy. Re-baselining is
correct only over a state you have verified is clean; doing it to silence a
report you have not read is how a compromise becomes permanent. The fix here is
what you watch, not when you snapshot.

<details>
<summary>Hint 1 — read the report, not just its length</summary>

Fifteen of the sixteen changes are under `/srv/app/current`. Those are the
deploy. The one that is not is the one that matters — find it.

</details>

<details>
<summary>Hint 2 — the watch list</summary>

`/etc/fim/watch.list` names what gets hashed. One entry is a directory rewritten
on every release. Remove that entry; keep the stable system paths.

```
$ grep -v '/srv/app' /etc/fim/watch.list > /tmp/w && sudo mv /tmp/w /etc/fim/watch.list
$ fim-check
```

</details>

<details>
<summary>Hint 3 — do not re-baseline</summary>

Leave `/var/lib/fim/baseline.sha256` alone. Re-taking it now records the
tampered sudoers file as known-good and hides the intrusion for real.

</details>

## Checking yourself

```
$ fim-check
CHANGED  /etc/sudoers.d/appdeploy
```

The deploy churn is gone from the report, and the sudoers tamper is the one
thing left — visible, because now the only things watched are the things that
were supposed to hold still.

<details>
<summary>Solution</summary>

```bash
# Stop watching the deploy directory; keep the stable system paths.
grep -v '/srv/app' /etc/fim/watch.list > /tmp/watch.list
sudo mv /tmp/watch.list /etc/fim/watch.list

# The baseline is left untouched — the intrusion has to stay visible.
fim-check
```

```
tampered_file: /etc/sudoers.d/appdeploy
stopped_watching: /srv/app/current
```

</details>
