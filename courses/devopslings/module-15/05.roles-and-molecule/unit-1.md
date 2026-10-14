---
title: "the playbook that only works on the box it was written on"
---

## The situation

`/root/platform/nodeagent.yml` installs the node agent's config. On this box
it works:

```
$ cd /root/platform && ansible-playbook nodeagent.yml
...
localhost : ok=3  changed=2  unreachable=0  failed=0
```

Another team wants the same agent on their hosts. They tried it on a fresh
Debian machine:

```
TASK [Agent config] ******
fatal: [new-host]: FAILED! => {"changed": false, "msg": "Destination directory /etc/nodeagent does not exist"}
```

The playbook never creates the `nodeagent` user or `/etc/nodeagent`. Someone
made both by hand on this box long ago, and the playbook has leaned on them
ever since. Its port and collector address are typed into the template, and
its last task appends a line to a log on every run. Nobody else can use it.

## Your objectives

1. Turn it into a role at `/root/platform/roles/nodeagent` that sets up the
   agent on a **clean** Debian host:
   - system group and user `nodeagent`
   - `/etc/nodeagent`, owned `root:nodeagent`, mode `0750`
   - `/etc/nodeagent/agent.conf`, owned `root:nodeagent`, mode `0640`, with
     the lines `port=<nodeagent_port>` and `collector=<nodeagent_collector>`
   - `/srv/nodeagent`, owned `nodeagent:nodeagent`
2. Put `nodeagent_port` (default `9100`) and `nodeagent_collector` (default
   `https://collector.internal:8443`) in `defaults/main.yml`.
3. Give the role a molecule scenario, `molecule/default`, that passes
   `molecule test` and whose verify step checks what the role does.

There is no docker in this box, so the platform team's molecule driver is in
`/root/platform/molecule-driver`. Its `create.yml` gives each instance a fresh
chroot of a stock `debian:trixie-slim` filesystem, and its `destroy.yml`
deletes it. A chroot has no init system, so the role sets up files and
accounts and does not start services.

## What you're being graded on

- The check applies your role, with defaults only, to a fresh Debian
  filesystem of its own. It must succeed and produce the state above.
- Applied a second time, it must report `changed=0`.
- With `nodeagent_port` and `nodeagent_collector` set in inventory, the
  config must use those values.
- `molecule test` in the role directory must pass, against a clean target,
  not this box.
- The same scenario, run against a copy of the role with an empty
  `tasks/main.yml`, must **fail**. A test that passes on a role that does
  nothing is not testing the role.

<details>
<summary>Hint 1 — the shape of a role</summary>

```
roles/nodeagent/
  defaults/main.yml      the tunables, lowest precedence
  tasks/main.yml         what it does
  templates/agent.conf.j2
  molecule/default/      the test
```

`defaults/` and `vars/` look alike and are opposites. Defaults lose to almost
everything, so callers can override them from inventory. Role `vars/` beat
inventory, so anything there is effectively fixed.

</details>

<details>
<summary>Hint 2 — a molecule scenario, with this driver</summary>

```
mkdir -p roles/nodeagent/molecule/default
cp molecule-driver/*.yml roles/nodeagent/molecule/default/
```

`molecule.yml`:

```yaml
driver:
  name: default
platforms:
  - name: nodeagent-clean
provisioner:
  name: ansible
```

`converge.yml` applies the role to the instance. Molecule exports the role
directory as `MOLECULE_PROJECT_DIRECTORY`, which works as a role name:

```yaml
- name: Converge
  hosts: all
  gather_facts: false
  tasks:
    - name: Apply the role under test
      ansible.builtin.include_role:
        name: "{{ lookup('env', 'MOLECULE_PROJECT_DIRECTORY') }}"
```

Then, from `roles/nodeagent`: `molecule test`. It destroys, creates, converges,
converges again to check idempotence, verifies and destroys.

</details>

<details>
<summary>Hint 3 — verify is where the test lives</summary>

Converge passing only proves nothing failed. Idempotence passing only proves
the second run changed nothing. A role with no tasks passes both.

`verify.yml` is a playbook that runs against the instance after converge.
Assert on the result:

```yaml
    - ansible.builtin.slurp:
        src: /etc/nodeagent/agent.conf
      register: conf
    - ansible.builtin.assert:
        that:
          - "'port=9100' in (conf.content | b64decode).splitlines()"
```

`ansible.builtin.stat` and `ansible.builtin.getent` cover owners, modes and
users.

</details>

<details>
<summary>Solution</summary>

`roles/nodeagent/defaults/main.yml`:

```yaml
nodeagent_port: 9100
nodeagent_collector: https://collector.internal:8443
```

`roles/nodeagent/templates/agent.conf.j2`:

```
# Managed by Ansible.
port={{ nodeagent_port }}
collector={{ nodeagent_collector }}
```

`roles/nodeagent/tasks/main.yml` creates everything the old playbook expected
to find already there:

```yaml
- name: Agent group
  ansible.builtin.group: {name: nodeagent, system: true}

- name: Agent user
  ansible.builtin.user:
    name: nodeagent
    group: nodeagent
    system: true
    create_home: false
    shell: /usr/sbin/nologin

- name: Agent config directory
  ansible.builtin.file:
    path: /etc/nodeagent
    state: directory
    owner: root
    group: nodeagent
    mode: "0750"

- name: Agent config
  ansible.builtin.template:
    src: agent.conf.j2
    dest: /etc/nodeagent/agent.conf
    owner: root
    group: nodeagent
    mode: "0640"

- name: Agent queue directory
  ansible.builtin.file:
    path: /srv/nodeagent
    state: directory
    owner: nodeagent
    group: nodeagent
    mode: "0750"
```

The "Record the install" task is gone. A line appended on every run is the
opposite of idempotent, and the package manager already records installs.

The scenario is the one from Hint 2, with a `verify.yml` that checks the
config lines, the user and the queue directory's owner. `nodeagent.yml` shrinks
to a play that applies the role:

```yaml
- name: Set up the node agent
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: roles/nodeagent
```

### Why the clean target matters

Run against this box, the old playbook passes, and so would a test of it. The
box has the user and the directory already, so the bug is invisible here. It
shows up only on a host that has never been touched, which is exactly where
someone reusing the role will run it.

That is the whole job of the molecule scenario: every run starts from a
filesystem nobody has touched by hand, so "works here" and "works" become the
same claim.

</details>
