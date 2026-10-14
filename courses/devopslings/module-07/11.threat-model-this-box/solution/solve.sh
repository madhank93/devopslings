#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The deliverable is the write-up. The gap: root's nightly cron job runs
# /opt/invoice/bin/backup.sh, which the invoice service user owns, so code
# execution as invoice becomes root at 02:15.
set -euo pipefail

install -d /root/answers
cat > /root/answers/threat-model.md <<'ANS'
# Threat model: invoice-1

asset: /etc/invoice/payment.env — payment provider key; whoever holds it can charge and refund as us
asset: /var/lib/invoice/invoices.db — every customer's invoices and address
asset: /home/deployer/.ssh/authorized_keys — decides who gets a shell as deployer

entry: tcp/8180 — invoice-web on every interface, reached from the internet through the load balancer
entry: tcp/22 — sshd on every interface, key-only, used by CI as deployer

boundary: internet -> invoice via HTTP requests to tcp/8180
boundary: internet -> deployer via ssh on tcp/22
boundary: deployer -> root via sudo systemctl restart invoice-web.service
boundary: invoice -> root via /opt/invoice/bin/backup.sh, which root runs nightly from cron

threat: can=send crafted HTTP requests to tcp/8180 and so run code as invoice gets=/etc/invoice/payment.env and /var/lib/invoice/invoices.db
threat: can=write files as invoice gets=root, by editing /opt/invoice/bin/backup.sh before 02:15
threat: can=hold the CI private key for deployer gets=a shell on tcp/22 and the ability to restart invoice-web

missing: /opt/invoice/bin/backup.sh — root runs it but invoice owns it and its directory; root executes code the service user can change

control: move the backup script to /usr/local/sbin/invoice-backup, root:root 0755, and point /etc/cron.d/invoice-backup at it | cost: app deploys stop shipping the backup script; changing it needs a root step outside the pipeline
control: AllowUsers deployer in sshd_config | cost: every new operator account needs an sshd change and a reload before it can log in
ANS

echo "threat model written to /root/answers/threat-model.md"
