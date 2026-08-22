---
kind: lesson
title: "the mail is sent, delivered, and filed under spam"
description: |
  Every nightly report from the app lands in the recipient's junk folder. The
  MTA is fine, the message arrives, and the receiving side files it anyway —
  because three DNS records that have nothing to do with the mail server are
  wrong, missing, and absent.
name: spf-dkim-dmarc
slug: spf-dkim-dmarc
createdAt: "2026-08-21"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop mailsink.service 2>/dev/null || true
      ip netns del mx 2>/dev/null || true
      ip link del to-mx 2>/dev/null || true
      install -d /opt/mail /etc/mail/dkim /root/answers /var/mail/received
      rm -f /var/mail/received/latest.eml /var/mail/received/verdicts.log

      ip netns add mx
      ip link add to-mx type veth peer name mx0
      ip link set mx0 netns mx
      ip addr add 10.93.0.1/24 dev to-mx
      ip link set to-mx up
      ip netns exec mx sh -c '
        ip link set lo up
        ip addr add 10.93.0.9/24 dev mx0
        ip link set mx0 up
      '

      # ---- the DKIM key pair -------------------------------------------
      #
      # 1024-bit, so the public key fits in a single 255-character DNS string
      # and the record can be written by hand. Publish 2048 in production and
      # split it across two quoted strings.
      openssl genrsa -out /etc/mail/dkim/mail.private 1024 2>/dev/null
      openssl rsa -in /etc/mail/dkim/mail.private -pubout \
        -out /etc/mail/dkim/mail.public 2>/dev/null
      chmod 600 /etc/mail/dkim/mail.private

      # ---- DNS for corp.example ----------------------------------------
      #
      # Three records decide whether mail from this domain is believed, and all
      # three are published here rather than on the mail server. That is the
      # lesson: the sending host is configured correctly and the domain is not.
      #
      # SPF names an address that has never sent this mail. There is no DKIM
      # key published at all, and no DMARC record, so the receiver has a
      # signature it cannot check and no policy to apply.
      install -d /etc/dnsmasq.d
      cat > /etc/dnsmasq.d/corp.conf <<'DNS'
      # Authoritative-ish answers for the corp.example zone.
      listen-address=10.93.0.1,127.0.0.1
      bind-interfaces
      no-resolv
      server=127.0.0.11

      address=/mx.partner.example/10.93.0.9

      txt-record=corp.example,"v=spf1 ip4:203.0.113.7 -all"
      DNS

      printf 'nameserver 10.93.0.1\noptions ndots:1\n' > /etc/resolv.conf

      systemctl unmask dnsmasq.service >/dev/null 2>&1 || true
      systemctl enable dnsmasq.service >/dev/null 2>&1 || true
      systemctl restart dnsmasq.service

      # ---- the receiving mail server ------------------------------------
      cat > /opt/mail/mailsink.py <<'PY'
      import datetime, email, email.utils, os, re, socketserver, dns.resolver, dkim, spf

      _resolver = dns.resolver.Resolver(configure=False)
      _resolver.nameservers = ["10.93.0.1"]
      dns.resolver.default_resolver = _resolver

      def authenticate(client_ip, helo, sender, raw):
          try:
              spf_result = spf.check2(i=client_ip, s=sender, h=helo)[0]
          except Exception:
              spf_result = "temperror"

          try:
              ok = dkim.verify(raw)
              dkim_result = "pass" if ok else "fail"
              start = raw.find(b"DKIM-Signature")
              found = re.search(rb"[;\s]d=([^;\s]+)", raw[start:]) if start >= 0 else None
              dkim_domain = found.group(1).decode() if found else "-"
          except Exception:
              dkim_result = "permerror"
              dkim_domain = "-"

          msg = email.message_from_bytes(raw)
          from_addr = msg.get("From", "")
          _, from_email = email.utils.parseaddr(from_addr)
          from_domain = from_email.split('@')[-1].lower() if '@' in from_email else ""

          try:
              dmarc_name = "_dmarc." + from_domain
              txt_records = dns.resolver.resolve(dmarc_name, "TXT")
              txt_string = "".join([str(r) for r in txt_records])
              policy_match = re.search(r"p=([a-z]+)", txt_string)
              policy = policy_match.group(1) if policy_match else "none"
              if (spf_result == "pass" and from_domain == sender.split('@')[-1].lower()) or \
                 (dkim_result == "pass" and dkim_domain == from_domain):
                  dmarc_result = "pass"
              else:
                  dmarc_result = "fail"
          except Exception:
              policy = "none"
              dmarc_result = "none"

          auth_header = f'Authentication-Results: mx.partner.example; spf={spf_result} smtp.mailfrom={sender}; dkim={dkim_result} header.d={dkim_domain}; dmarc={dmarc_result} (p={policy}) header.from={from_domain}'
          return auth_header.encode() + b"\r\n" + raw, spf_result, dkim_result, dmarc_result

      class Session(socketserver.StreamRequestHandler):
          def handle(self):
              self.wfile.write(b"220 mx.partner.example ESMTP\r\n")
              helo = ""
              sender = ""
              while True:
                  line = self.rfile.readline()
                  if not line:
                      return
                  line = line.strip()
                  verb = line.upper()
                  if verb.startswith(b"EHLO ") or verb.startswith(b"HELO "):
                      helo = line.split()[-1].decode()
                      self.wfile.write(b"250 ok\r\n")
                  elif verb.startswith(b"MAIL FROM:"):
                      found = re.search(rb"<([^>]*)>", line)
                      sender = found.group(1).decode() if found else ""
                      self.wfile.write(b"250 ok\r\n")
                  elif verb.startswith(b"RCPT TO:"):
                      self.wfile.write(b"250 ok\r\n")
                  elif verb == b"DATA":
                      self.wfile.write(b"354 end with .\r\n")
                      data = []
                      while True:
                          line = self.rfile.readline()
                          if line == b".\r\n":
                              break
                          data.append(line)
                      raw = b"".join(data)
                      try:
                          result, spf_result, dkim_result, dmarc_result = authenticate(
                              self.client_address[0], helo, sender, raw)
                          os.makedirs("/var/mail/received", exist_ok=True)
                          with open("/var/mail/received/latest.eml", "wb") as f:
                              f.write(result)

                          verdict = f"{datetime.datetime.now().isoformat(timespec='seconds')} spf={spf_result} dkim={dkim_result} dmarc={dmarc_result}\n"
                          with open("/var/mail/received/verdicts.log", "a") as f:
                              f.write(verdict)
                          self.wfile.write(b"250 accepted\r\n")
                      except Exception:
                          self.wfile.write(b"250 accepted\r\n")
                  elif verb == b"RSET" or verb == b"NOOP":
                      self.wfile.write(b"250 ok\r\n")
                  elif verb == b"QUIT":
                      self.wfile.write(b"221 bye\r\n")
                      return
                  else:
                      self.wfile.write(b"250 ok\r\n")

      class Server(socketserver.ThreadingTCPServer):
          allow_reuse_address = True

      Server(("10.93.0.9", 2525), Session).serve_forever()
      PY

      cat > /opt/mail/sendmail.py <<'PY'
      import email.message, email.utils, smtplib, sys, dkim

      msg = email.message.EmailMessage()
      msg["From"] = "alerts@corp.example"
      msg["To"] = "ops@partner.example"
      msg["Subject"] = "nightly backup report"
      msg["Date"] = email.utils.formatdate(localtime=True)
      msg["Message-ID"] = email.utils.make_msgid(domain="corp.example")
      msg.set_content("3 volumes, 0 errors.\n")

      raw = msg.as_bytes()

      try:
          sig = dkim.sign(
              raw,
              selector=b"mail",
              domain=b"corp.example",
              privkey=open("/etc/mail/dkim/mail.private", "rb").read(),
              include_headers=[b"from", b"to", b"subject", b"date"],
          )
          signed = sig + raw
      except Exception as exc:
          print("send failed: %s" % exc)
          sys.exit(1)

      try:
          server = smtplib.SMTP("10.93.0.9", 2525, timeout=10)
          server.sendmail("alerts@corp.example", ["ops@partner.example"], signed)
          server.quit()
      except Exception as exc:
          print("send failed: %s" % exc)
          sys.exit(1)
      print("sent")
      PY

      printf '#!/bin/sh\nexec /usr/bin/python3 /opt/mail/sendmail.py "$@"\n' > /usr/local/bin/send-report
      chmod 755 /usr/local/bin/send-report
      sha256sum /opt/mail/sendmail.py /opt/mail/mailsink.py > /opt/mail/checksums

      printf '[Unit]\nDescription=partner MX, checks SPF DKIM DMARC\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/mx\nExecStart=/usr/bin/python3 /opt/mail/mailsink.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/mailsink.service
      systemctl daemon-reload
      systemctl enable --now mailsink.service >/dev/null 2>&1

      for _ in $(seq 1 20); do
        (exec 3<>/dev/tcp/10.93.0.9/2525) 2>/dev/null && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      Every nightly report this app sends lands in the recipient's spam folder.
      The mail is not bounced and it is not lost — it arrives, and it is filed.

      Send one and read what the receiving side thought of it:

        $ send-report
        sent
        $ head -1 /var/mail/received/latest.eml

      The partner's MX is at 10.93.0.9 and it writes an Authentication-Results
      header on everything it accepts. Right now that header says spf=fail,
      dkim=fail and dmarc=none, and none of those are facts about the mail
      server — they are facts about DNS.

      The domain is corp.example and this box serves its zone from
      /etc/dnsmasq.d/corp.conf. The DKIM signing key is at
      /etc/mail/dkim/mail.private and its public half is next to it; the sender
      signs with the selector "mail".

      Three things to do.

      1. Make one message authenticate on all three:

           spf=pass  dkim=pass  dmarc=pass

         Everything is published in DNS. /opt/mail is shipped and checksummed:
         do not edit the sender or the receiver.

      2. Publish a DMARC policy that asks for something. p=none tells the world
         to do nothing, which is where this domain already is.

      3. Write /root/answers/mail.md, exactly two lines:

           dkim_record_name: <the DNS name the receiver looks up for the key>
           dmarc_needs: <how many of SPF and DKIM must pass and align: one or both>

      SPF authorises the machine that sent the message. DKIM proves the message
      was not altered and was signed by the domain. DMARC is the policy that
      binds either of them to the address in the From header — and it is the
      only one of the three the recipient's filter actually acts on.
      Q

      echo "scenario ready — the mail sends, and the receiver does not believe it"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # ---- the sender and the MX are not yours -------------------------
      if ! sha256sum -c /opt/mail/checksums >/dev/null 2>&1; then
        echo "not yet: something under /opt/mail has been edited."
        echo "         The sender signs correctly and the receiver checks honestly."
        echo "         Everything this exercise turns on is published in DNS."
        exit 1
      fi

      # ---- the records, as the resolver serves them --------------------
      spf=$(dig +short TXT corp.example @10.93.0.1 2>/dev/null | tr -d '"')
      dmarc=$(dig +short TXT _dmarc.corp.example @10.93.0.1 2>/dev/null | tr -d '"')

      case "$spf" in
        *"+all"*|*"?all"*)
          echo "not yet: the SPF record ends in $(printf '%s' "$spf" | grep -o '[+?~-]all')."
          echo "         That authorises every host on the internet to send as this"
          echo "         domain, which passes the check by giving up on it. Name the"
          echo "         address that actually sends the mail and end with -all."
          exit 1
          ;;
      esac

      case "$dmarc" in
        "")
          echo "not yet: there is no TXT record at _dmarc.corp.example."
          echo "         Without one the receiver has no policy to apply and reports"
          echo "         dmarc=none, whatever SPF and DKIM did."
          exit 1
          ;;
        *p=none*)
          echo "not yet: the DMARC record says p=none: $dmarc"
          echo "         That is the policy this domain already had. Ask for"
          echo "         quarantine or reject."
          exit 1
          ;;
      esac

      # ---- send one and read the verdict -------------------------------
      : > /var/mail/received/latest.eml
      out=$(send-report 2>&1 || true)
      if [ "$out" != "sent" ]; then
        echo "not yet: send-report did not send: $out"
        exit 1
      fi

      for _ in $(seq 1 10); do
        [ -s /var/mail/received/latest.eml ] && break
        sleep 0.5
      done

      results=$(head -1 /var/mail/received/latest.eml)
      case "$results" in
        *Authentication-Results*) ;;
        *)
          echo "not yet: the MX did not record an Authentication-Results header."
          echo "         It said: ${results:-nothing at all}"
          exit 1
          ;;
      esac

      fail=0

      case "$results" in
        *spf=pass*) ;;
        *)
          fail=1
          echo "not yet: $(printf '%s' "$results" | grep -o 'spf=[a-z]*')"
          echo "         SPF asks: is the IP that delivered this message allowed to"
          echo "         send for the envelope sender's domain? The mail leaves this"
          echo "         box on 10.93.0.1. Read the record and see which address it"
          echo "         names instead:"
          echo "           dig +short TXT corp.example"
          ;;
      esac

      case "$results" in
        *dkim=pass*) ;;
        *)
          fail=1
          echo "not yet: $(printf '%s' "$results" | grep -o 'dkim=[a-z]*')"
          echo "         The receiver found a signature and could not check it: there"
          echo "         is no key published to check it against. The sender signs with"
          echo "         selector 'mail', so the key has to be published at"
          echo "         mail._domainkey.corp.example as v=DKIM1; k=rsa; p=<base64>."
          echo "           openssl rsa -in /etc/mail/dkim/mail.private -pubout 2>/dev/null \\"
          echo "             | grep -v '^-' | tr -d '\\n'"
          ;;
      esac

      case "$results" in
        *dmarc=pass*) ;;
        *)
          fail=1
          echo "not yet: $(printf '%s' "$results" | grep -o 'dmarc=[a-z]*')"
          echo "         DMARC needs one of SPF or DKIM to pass *and* to be aligned"
          echo "         with the domain in the From header. Both of those have to be"
          echo "         true of the same domain, corp.example."
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      # ---- the answers -------------------------------------------------
      if [ ! -s /root/answers/mail.md ]; then
        echo "not yet: /root/answers/mail.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/mail.md)
      rec=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*dkim_record_name[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)
      needs=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*dmarc_needs[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)

      fail=0

      case "$rec" in
        *mail._domainkey.corp.example*) ;;
        "")
          fail=1
          echo "not yet: no dkim_record_name line in /root/answers/mail.md."
          ;;
        *_domainkey*)
          fail=1
          echo "not yet: you said dkim_record_name=$rec."
          echo "         Right shape, wrong name. The selector the sender signs with"
          echo "         goes in front of _domainkey, and the domain after it."
          ;;
        *)
          fail=1
          echo "not yet: you said dkim_record_name=$rec."
          echo "         The receiver builds that name from two tags in the"
          echo "         DKIM-Signature header — s= and d=:"
          echo "           grep -a DKIM-Signature -A2 /var/mail/received/latest.eml"
          ;;
      esac

      case "$needs" in
        *one*|*either*|*1*) ;;
        "")
          fail=1
          echo "not yet: no dmarc_needs line in /root/answers/mail.md."
          ;;
        *both*|*two*|*2*)
          fail=1
          echo "not yet: you said dmarc_needs=$needs."
          echo "         Either one is enough, which is the point of having two: mail"
          echo "         that is forwarded loses SPF and keeps DKIM, and a mailing"
          echo "         list can break DKIM and keep SPF."
          ;;
        *)
          fail=1
          echo "not yet: you said dmarc_needs=$needs."
          echo "         One or both?"
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — spf=pass, dkim=pass and dmarc=pass on a message the receiver"
      echo "       authenticated itself, with a policy that asks for something and an"
      echo "       SPF record that still says -all."
