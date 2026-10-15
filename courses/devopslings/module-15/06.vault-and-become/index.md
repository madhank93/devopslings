---
kind: lesson
title: "the sudo password is in group_vars, and in git"
description: |
  Nobody wanted to type -K on every deploy, so deploy's sudo password went
  into group_vars/all.yml and was committed. Encrypt it with ansible-vault so
  the run can still read it, keep the vault password out of the repository,
  and deal with the fact that the old password is already in the history.
name: vault-and-become
slug: vault-and-become
createdAt: "2026-10-14"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      # docker exec can hand out umask 0000; a world-writable repo makes
      # ansible ignore its ansible.cfg.
      umask 022
      userdel -r deploy 2>/dev/null || true
      rm -rf /home/deploy /etc/billing /etc/sudoers.d/deploy

      useradd -m -s /bin/bash deploy
      echo 'deploy:labonly-Kq7vRm2x-deploy' | chpasswd
      echo 'deploy ALL=(ALL:ALL) ALL' > /etc/sudoers.d/deploy
      chmod 0440 /etc/sudoers.d/deploy

      runuser -l deploy -c '
        set -e
        git config --global user.name "Dana Deploy"
        git config --global user.email "dana@billing.example.test"
        git config --global init.defaultBranch main
        mkdir -p infra/group_vars infra/templates
        cd infra
        git init -q

        printf "%s\n" "[defaults]" "inventory = inventory.ini" > ansible.cfg
        printf "%s\n" "[app]" "localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3" > inventory.ini
        printf "%s\n" "app_version: \"4.1.0\"" > group_vars/all.yml
        printf "%s\n" "# Managed by Ansible." "version={{ app_version }}" > templates/app.conf.j2
        printf "%s\n" \
          "- name: Deploy billing config" \
          "  hosts: app" \
          "  gather_facts: false" \
          "  become: true" \
          "  tasks:" \
          "    - name: Config directory" \
          "      ansible.builtin.file:" \
          "        path: /etc/billing" \
          "        state: directory" \
          "        mode: \"0755\"" \
          "    - name: Billing config" \
          "      ansible.builtin.template:" \
          "        src: templates/app.conf.j2" \
          "        dest: /etc/billing/app.conf" \
          "        owner: root" \
          "        group: root" \
          "        mode: \"0600\"" > site.yml
        git add -A
        git commit -qm "billing deploy playbook"

        printf "%s\n" "" "# so nobody has to type -K on every deploy" \
          "ansible_become_password: labonly-Kq7vRm2x-deploy" >> group_vars/all.yml
        git commit -qam "store become password"

        sed -i "s/4.1.0/4.2.0/" group_vars/all.yml
        git commit -qam "billing 4.2.0"

        ansible-playbook site.yml >/dev/null
      '
      echo "scenario ready: /home/deploy/infra deploys with deploy's sudo password in plaintext"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      repo=/home/deploy/infra
      old=labonly-Kq7vRm2x-deploy
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      chown deploy "$work"

      in_repo() { runuser -l deploy -c "cd $repo && $1"; }
      dgit() { runuser -u deploy -- git -C "$repo" "$@"; }

      if [ ! -d "$repo/.git" ]; then
        echo "not yet: $repo is not a git repository any more"
        exit 1
      fi

      if sudo -l -U deploy 2>/dev/null | grep -q NOPASSWD \
         || printf 'not-the-password\n' | runuser -u deploy -- sudo -S -k -p '' true >/dev/null 2>&1; then
        echo "not yet: deploy can sudo without a password (NOPASSWD or !authenticate)"
        echo "         that removes the secret instead of protecting it, and hands root"
        echo "         to anything that runs as deploy. Keep the password; vault it."
        exit 1
      fi

      # 1. Nothing in the working tree may hold the leaked password.
      hits=$(grep -rlF --exclude-dir=.git -- "$old" "$repo" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        echo "not yet: the sudo password is in plaintext in:"
        printf '%s\n' "$hits" | sed "s|^$repo/|           |"
        exit 1
      fi

      # 2. The run has to find the vault password without asking, from outside the repo.
      cfg=$(in_repo "ansible-config dump --only-changed --format json" 2>/dev/null || echo '[]')
      pwfiles=$(printf '%s' "$cfg" | jq -r '
        .[] | select(.name? == "DEFAULT_VAULT_PASSWORD_FILE" or .name? == "DEFAULT_VAULT_IDENTITY_LIST")
            | .value | if type == "array" then .[] else . end' 2>/dev/null \
        | sed 's/^[^@]*@//' | grep -v '^prompt$' || true)
      if [ -z "$pwfiles" ]; then
        echo "not yet: ansible in $repo has no vault password file configured"
        echo "         the check runs ansible-playbook as deploy with no prompt. Point"
        echo "         vault_password_file (ansible.cfg) or ANSIBLE_VAULT_PASSWORD_FILE at it."
        exit 1
      fi
      dgit cat-file --batch-all-objects --batch > "$work/objects" 2>/dev/null || true
      for f in $pwfiles; do
        case "$f" in "~/"*) f="/home/deploy/${f#\~/}" ;; esac
        real=$(cd "$repo" && realpath -m "$f")
        case "$real" in
          "$repo"|"$repo"/*)
            echo "not yet: the vault password file $f is inside the repository"
            echo "         .gitignore keeps it out of one commit; it does not keep it out of"
            echo "         a tarball, a backup, a CI workspace or the next 'git add -f'."
            echo "         Keep it outside the repo, e.g. in deploy's home."
            exit 1 ;;
        esac
        if [ ! -e "$real" ]; then
          echo "not yet: the configured vault password file $f does not exist"
          exit 1
        fi
        if [ -f "$real" ] && [ -n "$(find "$real" -perm /077 2>/dev/null || true)" ]; then
          echo "not yet: the vault password file $f is readable by other users ($(stat -c %A "$real"))"
          echo "         it unlocks every secret in the repo: chmod 600."
          exit 1
        fi
        # The key itself, as ansible will read it: an executable file is run.
        if [ -x "$real" ]; then
          key=$(runuser -l deploy -c "$(printf '%q' "$real")" 2>/dev/null || true)
        else
          key=$(cat "$real" 2>/dev/null || true)
        fi
        if [ -n "$key" ] && { grep -rqF -- "$key" "$repo" 2>/dev/null || grep -qF -- "$key" "$work/objects"; }; then
          echo "not yet: the vault key from $f is still in $repo, in a file or in git history"
          echo "         anyone with a clone can decrypt whatever it encrypted, history included."
          echo "         Change deploy's password again and vault it with a new key that"
          echo "         never enters the repo."
          exit 1
        fi
      done

      if [ -z "$(grep -rlE '^\$ANSIBLE_VAULT;|!vault' "$repo/group_vars" 2>/dev/null || true)" ]; then
        echo "not yet: nothing under group_vars is vault-encrypted"
        echo "         ansible-vault encrypt a vars file, or encrypt_string the one value."
        exit 1
      fi

      # 3. The leaked password has been public since it was committed.
      if printf '%s\n' "$old" | runuser -u deploy -- sudo -S -k -p '' true >/dev/null 2>&1; then
        commits=$(dgit log --all -S"$old" --format='%h %s' 2>/dev/null || true)
        echo "not yet: the old password still works for 'sudo' as deploy"
        if [ -n "$commits" ]; then
          echo "         the history still has it. Commits that added or removed it:"
          printf '%s\n' "$commits" | sed 's/^/           /'
          echo "         encrypting the file in a new commit leaves every old commit, and"
          echo "         every clone of them, as it was."
        else
          echo "         it is no longer in the history, but it was committed, and any clone"
          echo "         or fetch made before the rewrite still has it."
        fi
        echo "         A leaked password gets changed, then vaulted."
        exit 1
      fi

      # 4. What the run will actually use as the become password.
      : > "$work/pw"
      chown deploy "$work/pw"
      if ! in_repo "ansible localhost -m ansible.builtin.copy -a 'content={{ ansible_become_password }} dest=$work/pw'" > "$work/decrypt.out" 2>&1; then
        echo "not yet: ansible could not read ansible_become_password as deploy"
        grep -E 'ERROR|FAILED|fatal' "$work/decrypt.out" | head -4 | cut -c1-200 | sed 's/^/           /' || true
        exit 1
      fi
      pw=$(cat "$work/pw")

      # 5. The run, as deploy, escalating with that password.
      rm -f /etc/billing/app.conf
      if ! in_repo "ansible-playbook site.yml" > "$work/run.out" 2>&1; then
        echo "not yet: ansible-playbook site.yml failed when run as deploy"
        if grep -qiE 'incorrect (sudo|become) password|duplicate become password prompt' "$work/run.out"; then
          echo "         sudo rejected the password: what is in the vault is not deploy's"
          echo "         current password."
        else
          grep -E 'fatal:|ERROR' "$work/run.out" | head -4 | cut -c1-200 | sed 's/^/           /' || true
        fi
        exit 1
      fi
      got=$(stat -c '%U %a' /etc/billing/app.conf 2>/dev/null || true)
      if [ "$got" != "root 600" ]; then
        echo "not yet: the run passed but /etc/billing/app.conf is '${got:-missing}', expected root-owned 600"
        exit 1
      fi

      # 6. The current password: in no file, and in no git object, reachable or not.
      hits=$(grep -rlF -- "$pw" "$repo" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        echo "not yet: deploy's current sudo password is in plaintext in:"
        printf '%s\n' "$hits" | sed "s|^$repo/|           |"
        exit 1
      fi
      if grep -qF -- "$pw" "$work/objects"; then
        commits=$(dgit log --all -S"$pw" --format='%h %s' 2>/dev/null || true)
        echo "not yet: deploy's current sudo password is in plaintext in a git object"
        if [ -n "$commits" ]; then
          printf '%s\n' "$commits" | sed 's/^/           added or removed in /'
        else
          echo "           no branch reaches it; it survives in a stash ('git stash list'),"
          echo "           or as an amended or reset commit kept by the reflog."
        fi
        exit 1
      fi

      echo "PASS: the become password is vaulted, the vault key lives outside the repo,"
      echo "      the leaked password no longer works, and the new one is in no git object."
---
