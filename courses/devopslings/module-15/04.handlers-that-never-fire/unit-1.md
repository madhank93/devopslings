---
title: "the config file says 200 and the service is still doing 50"
---

## The situation

The edge rate limiter was raised from 50 to 200 requests per second this
morning. The change went into `group_vars/edge.yml`, and the playbook was run.
The file on disk is right:

```
$ grep requests /etc/ratelimiter/ratelimiter.conf
requests_per_second = 200
```

The service disagrees. It reports what it actually loaded:

```
$ curl -s 127.0.0.1:8471/
burst=100
requests_per_second=50
```

Someone has already run the playbook again, twice, to "push it through". It
did nothing either time.

Everything is in `/root/ansible`. Run it with `cd /root/ansible &&
ansible-playbook site.yml`.

## Your objectives

1. Find out why the service never picked up the new file.
2. Fix the playbook so a config change restarts or reloads the service.
3. Get the running service onto the config that is on disk.

The obvious fix is a task that restarts the service on every run. It makes the
symptom go away. It is also wrong, and the check looks for it.

## What you're being graded on

First, that what the service is running matches the file right now. Then the
check runs your playbook three times, with `-e ratelimiter_rps=<n>` to force a
change:

- a run that changes the config restarts or reloads the service exactly once,
  and the new value is live afterwards
- the same run again, with nothing to change, does not restart it at all
- a run that puts your `group_vars` value back restarts it once more

It counts restarts and reloads from the service's own load log in
`/var/lib/ratelimiter/loads`.

<details>
<summary>Hint 1 — read the whole run, not the recap</summary>

```
$ ansible-playbook site.yml
TASK [Write ratelimiter config] ******
ok: [localhost]
TASK [Ensure ratelimiter is running] ******
ok: [localhost]
TASK [Install logrotate policy] ******
fatal: [localhost]: FAILED! => {"msg": "Could not find or access 'files/ratelimiter.logrotate'..."}
```

The config task is `ok`. It was `changed` once, on the run that wrote 200, and
that run also failed on the logrotate task.

</details>

<details>
<summary>Hint 2 — when handlers run</summary>

A `notify` does not restart anything. It queues the handler, and the queue
is flushed at the end of the play, after every task has run.

If a task fails before then, the play stops for that host and the queue is
thrown away. The next run sees the file already correct, reports `ok`,
notifies nothing, and the restart is gone for good.

Two things follow. Fixing the failing task stops it happening next time, but
does not bring back the restart you already lost. And `force_handlers: true`
on the play (or `--force-handlers`) makes Ansible run the queued handlers even
when a later task fails.

</details>

<details>
<summary>Hint 3 — the handler is called, and still does nothing</summary>

Once the play stops failing, change the value and watch:

```
RUNNING HANDLER [Restart ratelimiter] ******
ok: [localhost]
```

`ok`, not `changed`. Read what the handler asks systemd for. `state: started`
means "make sure it is running". It is already running, so there is nothing to
do. A handler that is meant to pick up new config needs `restarted`, or
`reloaded` if the service supports it. This one reloads on SIGHUP.

</details>

<details>
<summary>Solution</summary>

Three separate faults combine here.

**1. The play fails after the config task.** The logrotate task asks for
`files/ratelimiter.logrotate` and the file is called `ratelimiter-logrotate`.
Rename one to match the other:

```
mv files/ratelimiter-logrotate files/ratelimiter.logrotate
```

**2. The handler cannot restart anything.** Change it to:

```yaml
  handlers:
    - name: Restart ratelimiter
      ansible.builtin.systemd_service:
        name: ratelimiter
        state: restarted
```

Add `force_handlers: true` to the play as well, so the next unrelated failure
cannot swallow a pending restart:

```yaml
- name: Configure the edge rate limiter
  hosts: edge
  gather_facts: false
  force_handlers: true
```

**3. The lost restart.** The file already says 200, so the template task will
report `ok` forever and never notify again. Restart once by hand:

```
systemctl restart ratelimiter
curl -s 127.0.0.1:8471/
```

Then run the playbook and check that it reports no changes and the service was
left alone.

### Why "always restart" is wrong

```yaml
    - name: Restart ratelimiter
      ansible.builtin.systemd_service:
        name: ratelimiter
        state: restarted
```

As a task, this runs every time. The service always ends up on the current
file, which is why it looks like a fix. But every deploy now restarts the
service, whether or not anything changed. That drops connections. The play
always reports `changed`, so you can no longer tell a run that did something
from one that did nothing. And it hides the real faults: a handler that could
never restart anything, and a play that loses its handlers when a later task
fails.

A handler says what you mean: restart **because** the config changed, and
only then.

### What to keep

A notification exists only in the memory of the run that made it. If that run
dies before the handlers, nothing on disk records that a restart is owed.
When a config change "didn't take", check the run that made the change, not
the latest one.

</details>
