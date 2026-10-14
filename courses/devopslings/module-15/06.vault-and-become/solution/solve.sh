#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The committed password is burned: change it before protecting the new one.
new='labonly-N3wPw9zT-deploy'
echo "deploy:$new" | chpasswd

runuser -l deploy -c "
  set -euo pipefail
  cd ~/infra

  # The vault key lives in deploy's home, never in the repo.
  ( umask 077 && openssl rand -hex 24 > ~/.vault-pass )
  printf '%s\n' '[defaults]' 'inventory = inventory.ini' 'vault_password_file = ~/.vault-pass' > ansible.cfg

  # Plain vars stay readable; the secret moves to its own encrypted file and
  # is referenced by name, so a grep for the variable still finds it.
  mkdir -p group_vars/all
  git mv group_vars/all.yml group_vars/all/vars.yml
  sed -i -e '/become password\|-K on every deploy/d' -e '/^ansible_become_password:/d' group_vars/all/vars.yml
  printf '%s\n' 'ansible_become_password: \"{{ vault_become_password }}\"' >> group_vars/all/vars.yml

  # Encrypted before it is ever staged, so no plaintext blob is created.
  ( umask 077 && printf 'vault_become_password: %s\n' '$new' > group_vars/all/vault.yml )
  ansible-vault encrypt group_vars/all/vault.yml

  git add -A
  git commit -qm 'vault the become password'
  ansible-playbook site.yml
"
