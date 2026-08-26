---
title: "harden sshd without locking yourself out of the box you are on"
---

## The situation

sshd on this box accepts two things it should not:

```
$ sshd -T | grep -Ei 'permitrootlogin|passwordauthentication'
permitrootlogin yes
passwordauthentication yes
```

Root can log in directly, and anyone can try passwords all night. Both should be
off: root logins are unaccountable and a standing brute-force target, and
password auth is the door every credential-stuffing bot knocks on. The fix is
two directives set to `no`.

The two directives are not the lesson. The lesson is that changing them in the
wrong order locks the account out for good — and on a real server, the account
it locks out is yours, mid-change, with no way back in.

## Why order is the whole thing

`PasswordAuthentication no` says: the only way in is a key. If no key is
installed when that line takes effect, there is no way in at all. The password
you were about to use is refused, and the key that would replace it does not
exist yet. The connection you are holding may survive on its existing
authentication, but the next one — after a reboot, a dropped Wi-Fi, a laptop
lid — cannot be made. You have locked the door and thrown away both copies.

So the sequence is fixed, and it is the same sequence you would use on a
production host you cannot afford to lose:

1. **Install the key first.** alice's public key is in `/root/deploy_key.pub`.
   It goes in her `authorized_keys`, and sshd is strict about the permissions:

   ```
   install -d -m 700 -o alice -g alice /home/alice/.ssh
   install -m 600 -o alice -g alice /root/deploy_key.pub \
       /home/alice/.ssh/authorized_keys
   ```

   sshd refuses to read a key file that the group or world can write, and it does
   so silently — the login just fails as if the key were wrong. A `700` directory
   and a `600` file are not tidiness; they are the difference between the key
   working and not.

2. **Prove the key works** *before* removing the fallback:

   ```
   ssh -i /root/deploy_key alice@localhost id -un   # -> alice
   ```

3. **Only now disable passwords and root**, and — the other half of not locking
   yourself out — never hand sshd a config it cannot parse:

   ```
   $ sshd -t          # says nothing and exits 0 if the config is valid;
                      #   prints the offending line and exits non-zero if not
   $ systemctl reload ssh
   ```

## reload, not restart; and validate, always

Two habits keep the daemon under you alive.

**`sshd -t` before every apply.** sshd will accept a config with a typo right up
until it tries to use it. A `restart` with a broken config stops the old daemon
and then fails to start the new one — the port goes dark and every session is
gone. `sshd -t` reads the same config and tells you it is broken while you can
still fix it. It costs nothing and it is the single habit that prevents most
SSH self-lockouts.

**`reload`, not `restart`.** `systemctl reload ssh` sends the daemon a signal to
re-read its config. Established connections are untouched; the listener is
replaced in place. `restart` tears the daemon down and builds it back up, and if
anything about the new config or the rebuild fails, it fails with the door shut.
On a box you are connected to, reload is how you change the lock without stepping
outside first.

The two together are belt and suspenders: validate so the new config is known
good, reload so a mistake you missed still cannot drop what is already connected.

## The habit

Every SSH hardening step is a change to the mechanism you are using to make the
change. That is what makes it different from editing a web server config: get it
wrong and you lose the ability to fix it. So the rule is to always leave a
working way in *before* removing the current one, and to prove the new way works
before trusting it. Install the key, test the key, then take the password away —
never the other order.

<details>
<summary>Hint 1 — install alice's key, and mind the permissions</summary>

```
sudo install -d -m 700 -o alice -g alice /home/alice/.ssh
sudo install -m 600 -o alice -g alice /root/deploy_key.pub \
    /home/alice/.ssh/authorized_keys
```

Then confirm it works while passwords are still on:

```
ssh -i /root/deploy_key alice@localhost id -un
```

sshd ignores an `authorized_keys` that is group- or world-writable, and says
nothing about why — so if the key login fails, check the modes first.

</details>

<details>
<summary>Hint 2 — the two directives</summary>

In `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
```

Do this only after the key login above has succeeded.

</details>

<details>
<summary>Hint 3 — validate, then reload</summary>

```
sudo sshd -t && sudo systemctl reload ssh
```

`sshd -t` catches a bad config before it can take the daemon down; `reload`
applies it without dropping connections. Never `restart` a daemon you are
depending on to stay reachable.

</details>

## Checking yourself

```
$ sshd -T | grep -Ei 'permitrootlogin|passwordauthentication'
permitrootlogin no
passwordauthentication no

$ ssh -i /root/deploy_key alice@localhost id -un
alice
```

Root and passwords off, alice still in with her key. If the second command
fails, the key is not installed correctly and disabling passwords has locked her
out — the exact failure this lesson exists to prevent.

<details>
<summary>Solution</summary>

```bash
# 1. Install the key first, with the modes sshd insists on.
sudo install -d -m 700 -o alice -g alice /home/alice/.ssh
sudo install -m 600 -o alice -g alice /root/deploy_key.pub \
    /home/alice/.ssh/authorized_keys

# 2. Prove it works before removing the fallback.
ssh -i /root/deploy_key alice@localhost id -un   # -> alice

# 3. Now harden, validate, reload.
sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin no/; \
             s/^PasswordAuthentication .*/PasswordAuthentication no/' \
    /etc/ssh/sshd_config
sudo sshd -t
sudo systemctl reload ssh
```

```
permit_root_login: no
password_authentication: no
validated_with: sshd -t
```

</details>
