#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# the gateway was serving the leaf alone, so a client holding only the root had
# no way to join the two; the intermediate has to travel with the leaf rather
# than be installed as an anchor on every client
cat /opt/pki/artifacts.corp.crt /opt/pki/intermediate.crt \
  > /opt/pki/artifacts.corp.chain.crt

jq '.sites."artifacts.corp".cert = "/opt/pki/artifacts.corp.chain.crt"' \
   /etc/vhosts/vhosts.json > /tmp/vhosts.json
mv /tmp/vhosts.json /etc/vhosts/vhosts.json

systemctl restart vhosts.service

ip=$(cat /opt/vhosts/address)
for _ in $(seq 1 20); do
  echo | openssl s_client -connect "$ip:8443" -servername artifacts.corp \
           -CAfile /opt/pki/root.crt -verify_return_error >/dev/null 2>&1 && break
  sleep 0.5
done

# an IP literal in a URL puts no server name in the ClientHello, so the default
# vhost answered with its own certificate; naming the host is the whole fix
sed -i "s#https://[0-9.]*:8443/publish#https://artifacts.corp:8443/publish#" \
  /usr/local/bin/publish

install -d /root/answers
cat > /root/answers/tls.md <<'ANS'
missing_link: Corp Issuing CA 2026
no_sni_vhost: internal-tools.corp
ANS
