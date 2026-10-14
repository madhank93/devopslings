#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/fleet

# host_vars files are matched to inventory names exactly; web7 is not web07.
mv host_vars/web7.yml host_vars/web07.yml

# Make the canary group part of web, so it also inherits web's connection vars.
printf '\n[web:children]\nweb_canary\n' >> hosts.ini

ansible web -m setup -a 'filter=ansible_hostname'
