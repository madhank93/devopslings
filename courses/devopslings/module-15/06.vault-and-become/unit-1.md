---
title: "the sudo password is in group_vars, and in git"
---

## The situation

The billing deploy runs as the `deploy` user, and writes a root-owned file,
so the play uses `become: true`. That needs deploy's sudo password. Typing
`-K` on every run got old, so somebody fixed it:

```
$ su - deploy
$ cd infra && git log --oneline
9c1e0a2 billing 4.2.0
51d7f3b store become password
0b4e8aa billing deploy playbook

$ cat group_vars/all.yml
app_version: "4.2.0"

# so nobody has to type -K on every deploy
ansible_become_password: labonly-Kq7vRm2x-deploy
```

Anyone who can read this repository can become root on every host it deploys
to.

## Your objectives

1. Encrypt the become password with `ansible-vault`. The playbook must still
   run as `deploy`, with `become`, without prompting.
2. Keep the vault password in a file **outside** the repository, readable
   only by `deploy`.
3. Deal with the copy that is already in the git history.

Work as `deploy` in `/home/deploy/infra` (`su - deploy`). You are root on the
box, so you can also change deploy's password.

## What you're being graded on

- No file in the repo holds the password in plaintext, and something under
  `group_vars` is vault-encrypted (`$ANSIBLE_VAULT;...`).
- Ansible in the repo is configured with a vault password file that sits
  outside the repo and is not readable by other users.
- `ansible-playbook site.yml`, run as `deploy` with no prompt, succeeds and
  writes `/etc/billing/app.conf` as root.
- The password the run uses appears in plaintext in **no git object**, not in
  any commit on any branch and not in an unreachable leftover.
- The password that was committed no longer works.

<details>
<summary>Hint 1 — encrypting, two ways</summary>

The whole file:

```
ansible-vault encrypt group_vars/all.yml
```

Or only the value, leaving the rest of the file readable:

```
ansible-vault encrypt_string --name ansible_become_password
```

A common layout is a plain `group_vars/all/vars.yml` that says
`ansible_become_password: "{{ vault_become_password }}"`, next to an encrypted
`group_vars/all/vault.yml` that defines `vault_become_password`. Grep still
finds where the variable comes from, and only the secret is unreadable.

</details>

<details>
<summary>Hint 2 — where the vault password goes</summary>

```
umask 077
openssl rand -hex 24 > ~/.vault-pass
```

and in `ansible.cfg`:

```
[defaults]
vault_password_file = ~/.vault-pass
```

A `.vault-pass` inside the repo, even in `.gitignore`, travels with every
tarball, backup and CI checkout of the directory, and one `git add -f` puts it
in history next to the secrets it unlocks.

</details>

<details>
<summary>Hint 3 — encrypting HEAD does not touch history</summary>

```
$ git log --all -p -S labonly-Kq7vRm2x-deploy --oneline
51d7f3b store become password
+ansible_become_password: labonly-Kq7vRm2x-deploy
```

A new commit with the file encrypted changes the newest version. Commit
`51d7f3b` still has the old one, and so does every clone and fetch made since.

You can rewrite history, but you cannot reach every copy that already left.
Once a secret has been committed, treat it as leaked: change it. After that,
the old value in history no longer opens anything.

</details>

<details>
<summary>Solution</summary>

As root, change the password that leaked:

```
passwd deploy
```

As deploy, make the vault key and point Ansible at it:

```
su - deploy
cd infra
( umask 077 && openssl rand -hex 24 > ~/.vault-pass )
printf '[defaults]\ninventory = inventory.ini\nvault_password_file = ~/.vault-pass\n' > ansible.cfg
```

Split the vars, and encrypt the secret **before** you stage it:

```
mkdir group_vars/all
git mv group_vars/all.yml group_vars/all/vars.yml
# in vars.yml: delete the plaintext line and the comment, then add
#   ansible_become_password: "{{ vault_become_password }}"
( umask 077 && echo 'vault_become_password: <the new password>' > group_vars/all/vault.yml )
ansible-vault encrypt group_vars/all/vault.yml
git add -A
git commit -m 'vault the become password'
ansible-playbook site.yml
```

### The order matters

Encrypting before `git add` matters. If you commit the plaintext and fix it in
the next commit, or amend it, git has already stored the plaintext as an
object. `git commit --amend` leaves the old commit unreachable, not deleted;
the reflog keeps it for 90 days, and `git cat-file` can still print it. The
check looks there too.

If it happened anyway, change the password again. That is quicker and surer
than cleaning the object store.

### Should you also scrub the history?

If the repo is shared, yes, as cleanup: `git filter-repo`, or `git
filter-branch` with an index filter, then a force-push and everyone re-clones.
But that is hygiene, not the fix. Copies made before the rewrite still hold
the old password. Changing it is what makes those copies harmless.

### What `become` changed here

`ansible_become_password` is not an application secret. It is deploy's
password to root on every host in the inventory. It needs at least the
protection the hosts themselves get. The alternative that looks easier, giving
deploy `NOPASSWD` sudo, removes the secret by letting anything that runs as
deploy become root without one.

</details>
