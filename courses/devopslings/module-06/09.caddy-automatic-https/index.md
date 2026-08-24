---
kind: lesson
title: "the certificate expired again, and renewing it is somebody's calendar reminder"
description: |
  The site is down because a certificate ran out, for the third time this year.
  There is an internal CA on this box that speaks ACME and will issue to anything
  that asks, and the server in front of the site can ask — which turns a yearly
  outage into a twelve-hour certificate nobody ever touches.
name: caddy-automatic-https
slug: caddy-automatic-https
createdAt: "2026-08-23"
timingSensitive: true

sandbox:
  stack: web-stack
  service: web

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop nginx.service haproxy.service caddy-site.service caddy-ca.service 2>/dev/null || true
      rm -rf /var/lib/caddy-ca /var/lib/caddy-site /etc/caddy /etc/ssl/site
      rm -f /root/answers/acme.md
      install -d /var/lib/caddy-ca /var/lib/caddy-site /etc/caddy /etc/ssl/site /root/answers

      grep -q ' web.internal' /etc/hosts || printf '127.0.0.1 web.internal\n' >> /etc/hosts
      grep -q ' acme.internal' /etc/hosts || printf '127.0.0.1 acme.internal\n' >> /etc/hosts

      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/reset' >/dev/null 2>&1 || true
      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/health 2>/dev/null | grep -q ok; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the origin on 172.32.0.11:8080 never came up"
        exit 1
      fi

      # ---- the internal CA, which already exists --------------------------
      #
      # The platform team runs this and its root is already in the box's trust
      # store. It speaks ACME, which is the same protocol Let's Encrypt speaks,
      # so anything that can get a public certificate automatically can get one
      # from here without changing how it works.
      cat > /etc/caddy/ca.caddyfile <<'CFG'
      {
          admin off
          # The CA has no business on port 80. Without this it opens one for
          # HTTP->HTTPS redirects, and since both servers bind with SO_REUSEPORT
          # the kernel hands http-01 validation requests to whichever listener it
          # likes — so issuance succeeds or fails at random.
          auto_https disable_redirects
          pki {
              ca local {
                  name "web-stack internal CA"
              }
          }
      }

      acme.internal:9443 {
          tls internal
          acme_server {
              ca local
          }
      }
      CFG

      cat > /etc/systemd/system/caddy-ca.service <<'UNIT'
      [Unit]
      Description=the internal ACME certificate authority
      After=network.target

      [Service]
      Environment=XDG_DATA_HOME=/var/lib/caddy-ca
      ExecStart=/usr/bin/caddy run --config /etc/caddy/ca.caddyfile --adapter caddyfile
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat > /etc/systemd/system/caddy-site.service <<'UNIT'
      [Unit]
      Description=the public site
      After=network.target caddy-ca.service

      [Service]
      Environment=XDG_DATA_HOME=/var/lib/caddy-site
      ExecStart=/usr/bin/caddy run --config /etc/caddy/site.caddyfile --adapter caddyfile
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl start --no-block caddy-ca.service

      root=/var/lib/caddy-ca/caddy/pki/authorities/local/root.crt
      for _ in $(seq 1 60); do
        [ -s "$root" ] && break
        sleep 0.5
      done
      if [ ! -s "$root" ]; then
        echo "the internal CA never produced a root certificate"
        journalctl -u caddy-ca -n 10 --no-pager 2>/dev/null | tail -5
        exit 1
      fi
      cp "$root" /usr/local/share/ca-certificates/web-stack-internal-ca.crt
      update-ca-certificates >/dev/null 2>&1

      acme=""
      for _ in $(seq 1 40); do
        if curl -s -o /dev/null -m 2 https://acme.internal:9443/acme/local/directory 2>/dev/null; then
          acme=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$acme" ]; then
        echo "the ACME directory never answered"
        exit 1
      fi

      # ---- the site, with a certificate somebody installed by hand ---------
      #
      # This is what the nginx config that used to serve this site turned into
      # when it was ported: a keypair on disk, named in the config, with a date
      # on it that nobody is watching.
      # Signed by the same internal CA, so the chain verifies and the only thing
      # wrong with it is the date — which is what an expiry outage actually looks
      # like, rather than a trust error.
      ca=/var/lib/caddy-ca/caddy/pki/authorities/local
      openssl req -newkey rsa:2048 -nodes \
        -keyout /etc/ssl/site/web.internal.key \
        -out /tmp/web.internal.csr \
        -subj "/CN=web.internal" >/dev/null 2>&1
      openssl x509 -req -in /tmp/web.internal.csr \
        -CA "$ca/intermediate.crt" -CAkey "$ca/intermediate.key" -CAcreateserial \
        -not_before 20250801000000Z -not_after 20260801000000Z \
        -extfile <(printf 'subjectAltName=DNS:web.internal\nextendedKeyUsage=serverAuth\n') \
        -out /tmp/web.internal.leaf >/dev/null 2>&1
      # The trust store has the root, not the intermediate, so the server has to
      # present both or the chain cannot be built.
      cat /tmp/web.internal.leaf "$ca/intermediate.crt" > /etc/ssl/site/web.internal.crt
      rm -f /tmp/web.internal.csr /tmp/web.internal.leaf
      chmod 0600 /etc/ssl/site/web.internal.key

      cat > /etc/caddy/site.caddyfile <<'CFG'
      {
          admin off
      }

      web.internal {
          # Installed by hand, renewed by remembering to. This is the line the
          # nginx config became.
          tls /etc/ssl/site/web.internal.crt /etc/ssl/site/web.internal.key

          reverse_proxy 172.32.0.11:8080
      }
      CFG

      systemctl start --no-block caddy-site.service
      for _ in $(seq 1 40); do
        curl -sk -o /dev/null -m 2 https://web.internal/health 2>/dev/null && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The site is down. Again.

        $ curl -s https://web.internal/health
        curl: (60) SSL certificate problem: certificate has expired

        $ echo | openssl s_client -connect web.internal:443 -servername web.internal 2>/dev/null \
            | openssl x509 -noout -dates -issuer

      Third time this year. The certificate is a file on disk named in
      /etc/caddy/site.caddyfile, it was installed by hand, and renewing it is a
      calendar reminder that somebody keeps missing.

      There is an internal certificate authority running on this box. It speaks
      ACME — the same protocol Let's Encrypt speaks — and it will issue to
      anything that asks:

        $ curl -s https://acme.internal:9443/acme/local/directory | head -5

      Its root is already in this box's trust store, which is why that curl
      verifies without -k.

      The site is Caddy: /etc/caddy/site.caddyfile, restarted with
      `systemctl restart caddy-site`. The CA is caddy-ca and is not yours to
      change.

      Three things to do.

      1. Serve https://web.internal/ with a certificate obtained from that CA
         automatically, so that `curl https://web.internal/health` verifies with
         no -k and no --cacert, and returns "ok".

      2. Do not keep the hand-installed certificate in the picture. The whole
         point is that nothing on disk has to be replaced by a human again.

      3. Prove renewal works. The grader will throw away the certificate the
         server is holding and expect it to get another one by itself, without
         anybody editing a file.

      Then write /root/answers/acme.md, exactly two lines:

        acme_directory: <url>
        cert_lifetime_hours: <number>

      acme_directory is the URL the server asks for certificates. The lifetime
      is what the CA actually issued — read the dates on the certificate you are
      now serving, and notice how short it is. That is the part that only works
      because nobody is doing it by hand.
      Q

      echo "scenario ready — expired hand-installed certificate, ACME CA waiting"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      site=https://web.internal/health

      served() {
        echo | timeout 10 openssl s_client -connect web.internal:443 \
          -servername web.internal 2>/dev/null | openssl x509 -noout "$1" 2>/dev/null || true
      }

      # ---- it serves, and it verifies without being told what to trust ------
      #
      # A server that has just been restarted may still be completing an order,
      # and a certificate that does not exist yet looks like a handshake error.
      # Give issuance a window before calling it a failure.
      body=""
      for _ in $(seq 1 20); do
        body=$(curl -s -m 15 "$site" 2>/dev/null || true)
        [ "$body" = "ok" ] && break
        sleep 2
      done
      if [ "$body" != "ok" ]; then
        why=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$site" 2>&1 || true)
        echo "not yet: https://web.internal/health did not return ok (curl said: ${why:-nothing})."
        detail=$(curl -sS -m 15 -o /dev/null "$site" 2>&1 || true)
        [ -n "$detail" ] && echo "         $detail"
        echo "         The certificate has to verify against the trust store this box"
        echo "         already has, which contains the internal CA's root and nothing"
        echo "         you would have to add."
        exit 1
      fi

      # ---- from the CA, not from a file --------------------------------------
      issuer=$(served -issuer)
      if ! printf '%s' "$issuer" | grep -q 'web-stack internal CA'; then
        echo "not yet: the certificate being served is issued by:"
        echo "         ${issuer:-nothing}"
        echo "         It has to come from the internal CA — the one whose ACME"
        echo "         directory is at https://acme.internal:9443/acme/local/directory."
        echo "         Caddy's own built-in issuer is a different CA, and nothing"
        echo "         trusts it here."
        exit 1
      fi

      if grep -qE '^[[:space:]]*tls[[:space:]]+/' /etc/caddy/site.caddyfile 2>/dev/null; then
        echo "not yet: /etc/caddy/site.caddyfile still names a certificate file."
        echo "         A file on disk is the thing that expires while nobody is looking."
        exit 1
      fi

      # ---- and it can get another one on its own -----------------------------
      #
      # Throw away what the server is holding and restart it. Nothing is edited,
      # nobody is asked: if issuance is automatic the certificate comes back by
      # itself, with a different serial.
      before=$(served -serial)
      if [ -z "$before" ]; then
        echo "not yet: could not read the serial of the certificate being served."
        exit 1
      fi

      # Everything the server had: the certificates, the issuance locks and the
      # ACME account. Removing only the certificate leaves locks behind from a
      # process stopped mid-order, and the next attempt waits those out instead
      # of ordering — which looks like renewal being broken when it is not.
      systemctl stop caddy-site.service 2>/dev/null || true
      rm -rf /var/lib/caddy-site/caddy
      systemctl start --no-block caddy-site.service 2>/dev/null || true

      after=""
      for _ in $(seq 1 60); do
        sleep 2
        now=$(served -serial)
        if [ -n "$now" ] && [ "$now" != "$before" ]; then
          after="$now"
          break
        fi
      done

      if [ -z "$after" ]; then
        echo "not yet: the certificate was removed and the server did not obtain a"
        echo "         new one within two minutes."
        echo "         serial before: $before"
        echo "         serial now:    ${now:-none}"
        echo "         The last thing the server said about it:"
        journalctl -u caddy-site -n 40 --no-pager 2>/dev/null \
          | grep -Ei 'tls.obtain|acme|error' | tail -3 | sed 's/^/         /'
        exit 1
      fi

      body=$(curl -s -m 15 "$site" 2>/dev/null || true)
      if [ "$body" != "ok" ]; then
        echo "not yet: a new certificate was issued and the site stopped verifying"
        echo "         afterwards."
        exit 1
      fi

      # ---- naming it ----------------------------------------------------------
      if [ ! -s /root/answers/acme.md ]; then
        echo "not yet: /root/answers/acme.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/acme.md)
      dir=$(printf '%s\n' "$low" | sed -n 's#^[[:space:]]*acme_directory[[:space:]]*[:=][[:space:]]*\([^[:space:]]*\).*#\1#p' | head -1)
      life=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*cert_lifetime_hours[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)

      if [ -z "$dir" ] || [ -z "$life" ]; then
        echo "not yet: /root/answers/acme.md needs an acme_directory line and a"
        echo "         cert_lifetime_hours line."
        exit 1
      fi

      fail=0
      dir=${dir%/}

      if [ "$dir" != "https://acme.internal:9443/acme/local/directory" ]; then
        fail=1
        echo "not yet: you said acme_directory=$dir."
        case "$dir" in
          http://*)
            echo "         The directory is served over HTTPS. An ACME client will not"
            echo "         talk to a plain-HTTP directory, which is worth knowing because"
            echo "         the error it gives says nothing about the scheme."
            ;;
          *letsencrypt*)
            echo "         That is the public CA. This box has no internet and the name"
            echo "         is internal; the CA that issued your certificate is on this"
            echo "         machine."
            ;;
          *)
            echo "         It is the URL in your own configuration, and it answers:"
            echo "         curl -s https://acme.internal:9443/acme/local/directory"
            ;;
        esac
      fi

      if [ "$life" != "12" ]; then
        fail=1
        echo "not yet: you said cert_lifetime_hours=$life."
        case "$life" in
          2160|8760|720|90)
            echo "         That is a public-CA sort of number, in days. Read the dates on"
            echo "         the certificate this CA actually issued you:"
            echo "         echo | openssl s_client -connect web.internal:443 \\"
            echo "           -servername web.internal 2>/dev/null | openssl x509 -noout -dates"
            ;;
          *)
            echo "         notBefore and notAfter on the certificate you are serving are"
            echo "         closer together than anybody would tolerate by hand."
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the site is served over HTTPS with a certificate issued by the"
      echo "       internal CA, no certificate file is named in the config, and"
      echo "       throwing the certificate away got a new one without a human."
