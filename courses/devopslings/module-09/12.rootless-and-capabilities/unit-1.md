---
title: "it needed one privileged thing, so it runs privileged"
---

## The situation

The egress shaper sets an MTU and a queueing discipline on its own interface.
When it was first written it failed:

```
RTNETLINK answers: Operation not permitted
```

Someone added `privileged: true`, the error went away, and that was eighteen
months ago. The service is small, it does one thing, and it now runs with more
authority over the host than the process that started it.

The question is not whether it needs a privilege. It does. The question is which
one, and what else came with the answer:

```
$ docker compose -p devopslings-caps run --rm --entrypoint sh shaper \
    -c 'capsh --decode=$(awk "/CapEff/{print \$2}" /proc/self/status)'
0x000001ffffffffff=cap_chown,cap_dac_override,cap_dac_read_search,cap_fowner,
cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_linux_immutable,…
```

## Your objectives

1. Keep the shaper working — it must still set the MTU and install the qdisc.
2. Give it exactly one capability: the one it uses, and nothing else.

## What you're being graded on

That the shaper still prints `shaped: mtu=1400 qdisc=tbf`; that the container's
effective capability set is exactly `CAP_NET_ADMIN`; and that a capability it
was not granted is one it genuinely cannot use — the grader tries to mount a
tmpfs inside it and requires that to be refused.

<details>
<summary>Hint 1 — what privileged actually turns on</summary>

`privileged: true` is not "a few more permissions". It grants every capability
in the kernel, exposes the host's devices to the container, and disables the
seccomp and AppArmor profiles that would otherwise stand between the container
and the syscall table.

Look at what the container holds now, and look at what a normal container holds:

```
docker compose -p devopslings-caps run --rm --entrypoint sh shaper \
  -c 'awk "/CapEff/{print \$2}" /proc/self/status'
docker run --rm alpine:3.20 sh -c 'awk "/CapEff/{print \$2}" /proc/self/status'
```

</details>

<details>
<summary>Hint 2 — find the one it needs</summary>

The operations are `ip link set … mtu` and `tc qdisc add`. Both go through
rtnetlink, and the kernel checks one capability for that.

`man 7 capabilities` names it, and the error the shaper started with —
`Operation not permitted`, `EPERM` — is what a capability check failing looks
like.

Docker grants fourteen capabilities by default and that one is not among them,
which is the whole reason this ever failed.

</details>

<details>
<summary>Hint 3 — drop first, then add</summary>

```yaml
services:
  shaper:
    cap_drop:
      - ALL
    cap_add:
      - SOMETHING
```

`cap_add` on its own leaves the fourteen defaults in place and adds a fifteenth.
Dropping `ALL` first is what makes the list say what the service actually needs
rather than what Docker happened to hand it.

</details>

<details>
<summary>Solution</summary>

```yaml
services:
  shaper:
    build: .
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
```

```
$ docker compose -p devopslings-caps run --rm shaper
shaped: mtu=1400 qdisc=tbf

$ docker compose -p devopslings-caps run --rm --entrypoint sh shaper \
    -c 'awk "/CapEff/{print \$2}" /proc/self/status'
0000000000001000

$ docker compose -p devopslings-caps run --rm --entrypoint sh shaper \
    -c 'mount -t tmpfs none /mnt'
mount: permission denied (are you root?)
```

One bit set. The shaper does its job, and the same container can no longer mount
a filesystem, load a module, or read another process's memory.

### The part worth remembering

Root inside a container is not one privilege, it is a **set of capabilities**,
and Docker already withholds most of them. The default set is fourteen:

```
cap_chown, cap_dac_override, cap_fowner, cap_fsetid, cap_kill, cap_setgid,
cap_setuid, cap_setpcap, cap_net_bind_service, cap_net_raw, cap_sys_chroot,
cap_mknod, cap_audit_write, cap_setfcap
```

Which is why `NET_BIND_SERVICE` — binding port 80 — needs no configuration at
all, and why `NET_ADMIN` does. When a container fails with `EPERM` on something
a real root user could do, the answer is almost always one named capability, and
`man 7 capabilities` is the list.

`--privileged` is the opposite of a diagnosis. It grants all of them plus device
access plus the loss of seccomp and AppArmor, so it makes any capability problem
disappear without telling you which one it was — and `CAP_SYS_ADMIN` alone, which
it includes, is enough to mount filesystems and is a documented route out of a
container. Reaching for it is understandable at 2am; leaving it in is how a
one-line shaper ends up with more authority than anything else on the host.

The pattern that scales: **drop `ALL`, add back what fails.** Run it with nothing,
read the `EPERM`, grant precisely that, repeat. The resulting list is documentation
— the next person can see what the service is allowed to do without running it.

Two things beyond the scope of this exercise but worth knowing they exist:

- **Non-root plus capabilities is not automatic.** Capabilities added with
  `cap_add` land in the container's bounding and permitted sets for uid 0. A
  process running as a non-root user does not inherit them; it needs either
  ambient capabilities or file capabilities set on the binary (`setcap`), and
  file capabilities on an image binary do not survive every runtime — on the one
  this lesson was written against, `setcap cap_net_admin+ep /sbin/ip` was present
  on the file at runtime and still did not take effect. Check, do not assume.
- **Rootless Docker** runs the daemon itself as an unprivileged user, so the
  container's root maps to your uid on the host. It changes what "root in the
  container" is worth from the outside; it does not change which capability the
  shaper needs on the inside.

In Kubernetes this is `securityContext.capabilities`, with the same `drop: [ALL]`
then `add:` shape, and `privileged: true` means the same thing there — with the
same reasons not to.

</details>
