#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# the public half of the signing key, as one base64 string with the PEM
# armour and the newlines taken out, which is the only form a TXT record can
# carry
pub=$(openssl rsa -in /etc/mail/dkim/mail.private -pubout 2>/dev/null \
      | grep -v '^-' | tr -d '\n')

cat > /etc/dnsmasq.d/corp.conf <<DNS
# Authoritative-ish answers for the corp.example zone.
listen-address=10.93.0.1,127.0.0.1
bind-interfaces
no-resolv
server=127.0.0.11

address=/mx.partner.example/10.93.0.9

# the address the mail actually leaves from, and nothing else
txt-record=corp.example,"v=spf1 ip4:10.93.0.1 -all"

# the selector the sender signs with
txt-record=mail._domainkey.corp.example,"v=DKIM1; k=rsa; p=$pub"

# a policy that asks for something; none is what the domain already had
txt-record=_dmarc.corp.example,"v=DMARC1; p=reject; rua=mailto:dmarc@corp.example"
DNS

systemctl restart dnsmasq.service

for _ in $(seq 1 20); do
  dig +short TXT _dmarc.corp.example @10.93.0.1 | grep -q DMARC1 && break
  sleep 0.5
done

install -d /root/answers
cat > /root/answers/mail.md <<'ANS'
dkim_record_name: mail._domainkey.corp.example
dmarc_needs: one
ANS
