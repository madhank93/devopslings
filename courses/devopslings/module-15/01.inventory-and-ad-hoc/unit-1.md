---
title: "twelve boxes, one command, and the two it never asked"
---

## The situation

The web tier is twelve boxes, `web01` to `web12`. The CMDB export in
`/root/fleet/cmdb.csv` lists them with their SSH ports. Someone has built an
Ansible inventory from it, and you want one fact from every box before a kernel
patch goes out:

```
$ cd /root/fleet
$ ansible web -m setup -a 'filter=ansible_kernel'
web03 | SUCCESS => {
    "ansible_facts": {
        "ansible_kernel": "6.12.48+deb13-amd64"
    },
    "changed": false
}
web02 | SUCCESS => {
...
[ERROR]: Task failed: Failed to connect to the host via ssh: ssh: connect to host 127.0.0.1 port 22: Connection refused
web07 | UNREACHABLE! => {
...
web10 | SUCCESS => {
...
```

Ten blocks of output, one of them red. Fix `web07` and it is all green. That
still leaves two boxes the command never asked. They produce no line, no error
and no warning, and a missing host is very hard to see in a long scroll of
JSON.

Every box here is an SSH server on this machine, on its own port, with its own
hostname. `ssh -p 2203 deploy@127.0.0.1 -i /root/.ssh/fleet_ed25519 hostname`
says `web03`. That makes them cheap to run, and they still behave like twelve
machines: a connection that reaches the wrong port reaches the wrong box.

## Your objectives

1. Find every box in `cmdb.csv` that `ansible web` misses, and the reason for
   each one.
2. Fix the inventory in `/root/fleet` so that `ansible web` reaches all twelve,
   each on its own connection.
3. Gather a fact from the whole group in one ad-hoc command, and check the count
   yourself.

Do not remove a host to make the run green. A host taken out of the inventory
is still in production. It just stops getting patched.

## What you're being graded on

From `/root/fleet`, with your `ansible.cfg`, group `web` must contain exactly
the twelve boxes in `cmdb.csv`. The grader then gathers `ansible_hostname` from
the group. Every host must answer, and each must answer with its own name. A
host whose settings land on some other box fails the check, even though Ansible
calls that a success.

<details>
<summary>Hint 1 — count before you read</summary>

Ask the inventory who is in the group before you ask the hosts anything:

```
ansible web --list-hosts
ansible-inventory --graph
```

`--list-hosts` prints a count in its header. Compare it with
`wc -l cmdb.csv`. The graph shows every group and the hosts under it, and it
shows the hosts in no group you expected.

</details>

<details>
<summary>Hint 2 — where a host's variables come from</summary>

```
ansible-inventory --host web07
ansible-inventory --host web06
```

Compare the two. Ansible loads `host_vars/<name>.yml` only when `<name>` is
exactly the inventory hostname. Nothing warns you about a file whose name
matches no host. It is skipped, and the host falls back to the defaults, here
SSH on port 22.

</details>

<details>
<summary>Hint 3 — groups do not nest by name</summary>

`[web_canary]` is a group of its own. Nothing about its name makes it part of
`web`. A group is part of another only when the parent lists it:

```ini
[web:children]
web_canary
```

The `[web:vars]` block applies to `web` and its children, so a host outside
`web` also misses the user and key it needs.

</details>

<details>
<summary>Solution</summary>

Count first:

```
$ ansible web --list-hosts | head -1
  hosts (10):
$ ansible-inventory --graph
@all:
  |--@ungrouped:
  |--@web:
  |  |--web01
  ...
  |  |--web10
  |--@web_canary:
  |  |--web11
  |  |--web12
```

Ten, not twelve. `web11` and `web12` were added for a canary rollout, in a group
that was never made part of `web`. Make it a child, so the canary hosts also get
the connection variables:

```
printf '\n[web:children]\nweb_canary\n' >> hosts.ini
```

Then `web07`. The error says port 22, and the CMDB says 2207:

```
$ ansible-inventory --host web07
{
    "ansible_host": "127.0.0.1",
    "ansible_ssh_private_key_file": "/root/.ssh/fleet_ed25519",
    "ansible_user": "deploy"
}
$ ls host_vars/
web01.yml  web02.yml  ...  web06.yml  web08.yml  ...  web7.yml
```

There is no `ansible_port`, because the file is called `web7.yml` and the host
is called `web07`. Rename it:

```
mv host_vars/web7.yml host_vars/web07.yml
```

Now the one command, and a count you can trust:

```
$ ansible web -m setup -a 'filter=ansible_hostname' | grep -c SUCCESS
12
```

### Why the silent failure is the dangerous one

An unreachable host is a failure Ansible knows about. It prints it in red and
the run exits non-zero. A host outside the pattern is not a failure at all. As
far as Ansible is concerned, it was asked to talk to ten hosts and talked to ten.
"All green" only means every host that was asked answered. It says nothing about
whether the right hosts were asked.

So the habit is to count. Check the host count in the inventory against the
source of truth before you trust any run. In a real fleet the inventory is
often generated from a CMDB or a cloud API, and that generation step is where
hosts go missing.

`ansible_connection=local` and copied ports are the other trap. They make the
red line go away, and the fact that comes back is from a different machine.
That is why the grader checks each box's hostname, not just that it answered.

</details>
