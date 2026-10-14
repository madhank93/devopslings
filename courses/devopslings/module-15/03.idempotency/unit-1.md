---
title: "the second run reports six changes, and the box looks fine"
---

## The situation

`/root/agent/site.yml` installs fleet-agent. It has already run once on this
box. Run it again:

```
$ cd /root/agent
$ ansible-playbook site.yml
...
PLAY RECAP *********************************************************************
box                        : ok=8    changed=6    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Nothing was wrong with the box, and nothing in the playbook changed. Six tasks
still say they changed something.

The obvious reading is that it does not matter. The result is the same every
time, so who cares what the recap says? The recap matters because it is the
only report you get. A run against two hundred boxes that always says
`changed=1200` cannot tell you that one box had drifted and was put back. Real
changes and noise look the same.

## Your objectives

1. Find out, for each of the six tasks, why it reports a change on a box that
   is already correct. There are four different reasons.
2. Fix the playbook (and the files it uses, if needed) so that a second run
   reports `changed=0`.
3. Keep the end state in `/root/agent/README` exactly as it is.

## What you're being graded on

The grader removes everything the playbook manages, runs it once and checks the
end state against the README. It runs it again and requires `changed=0`, with
the same end state.

Then it puts things out of place one at a time: the user's shell, the binary,
`max_conn`, the env file and the log file's mode. After each one, the next run
has to put it back **and report that it did**. `changed_when: false` makes the
recap quiet by making it lie, and this is how the grader tells the difference.

<details>
<summary>Hint 1 — which tasks, and what they actually do</summary>

Run it with `--diff` to see what a "changed" task actually changed:

```
ansible-playbook site.yml --diff
```

A task that shows a diff on every run really is rewriting something. A
`shell` or `command` task never shows a diff, because Ansible cannot see what a
command did. It ran, so Ansible reports it as changed.

</details>

<details>
<summary>Hint 2 — the four causes</summary>

- **`shell` and `command`.** Ansible has no idea whether `useradd` or
  `install` changed anything, so it always says yes. The modules that know
  are `user` and `copy`. They compare first and act only if needed.
- **Two tasks own one file.** `copy` writes `max_conn = 256`, then
  `lineinfile` changes it to 512. Next run, `copy` sees 512, "fixes" it back
  to 256, and `lineinfile` "fixes" it again. Each is correct alone, and
  together they fight forever.
- **A template that renders something new each run.** `ansible_date_time` is
  different every time, so the rendered file never matches the one on disk.
- **`state: touch`.** Touching a file updates its timestamps. That is a change,
  every time, by definition.

</details>

<details>
<summary>Hint 3 — why not `changed_when: false`</summary>

It is a filter on the report, not a fix. The task still runs. It just never
says so. If the user's shell drifts, the shell task either fixes it silently or
does not fix it at all, and either way the recap says nothing happened.

`changed_when` is for a command whose output *tells* you whether it changed
something:

```yaml
- ansible.builtin.command: some-tool --apply
  register: r
  changed_when: "'already up to date' not in r.stdout"
```

That is a real test. `false` is not.

</details>

<details>
<summary>Solution</summary>

One owner per file, and modules that compare before they act. In
`files/agent.conf`, put the real value:

```
max_conn = 512
```

In `templates/agent.env.j2`, drop the time from the header:

```
# Managed by Ansible.
FLEET_ROLE=web
FLEET_NODE={{ inventory_hostname }}
```

And the playbook:

```yaml
- name: fleet-agent is installed and configured
  hosts: agents
  tasks:
    - name: service account exists
      ansible.builtin.user:
        name: fleetagent
        system: true
        create_home: false
        shell: /usr/sbin/nologin

    - name: agent binary is installed
      ansible.builtin.copy:
        src: fleet-agent
        dest: /usr/local/bin/fleet-agent
        mode: "0755"

    - name: config directory exists
      ansible.builtin.file:
        path: /etc/fleet-agent
        state: directory
        mode: "0755"

    - name: config is in place
      ansible.builtin.copy:
        src: agent.conf
        dest: /etc/fleet-agent/agent.conf
        mode: "0644"

    - name: environment file is rendered
      ansible.builtin.template:
        src: agent.env.j2
        dest: /etc/fleet-agent/agent.env
        mode: "0644"

    - name: log file exists
      ansible.builtin.file:
        path: /var/log/fleet-agent.log
        state: touch
        owner: fleetagent
        mode: "0640"
        access_time: preserve
        modification_time: preserve
```

```
$ ansible-playbook site.yml | tail -2
box                        : ok=7    changed=0    unreachable=0    failed=0    ...
```

`state: touch` with both times preserved creates the file when it is missing
and otherwise only enforces owner and mode. `state: file` would be the obvious
choice, but it refuses to create a file, so it fails on a new box.

### What changed=0 is for

Every module here works the same way. Read the current state, compare it with
the one described, act only on the difference, and report whether there was
one. A `changed` count you can trust is what turns a playbook from a script you
re-run into a check you can run anywhere. `changed=0` means the box matches.
`changed=1` means it did not, and the recap names the task that fixed it.

Module 02's idempotent-by-construction lesson made a shell script safe to run
twice. That was half of it. This is the other half: the run also has to
*report* honestly whether it did anything.

</details>
