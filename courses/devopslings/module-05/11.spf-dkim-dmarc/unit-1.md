---
title: "the mail is sent, delivered, and filed under spam"
---

## The situation

Every nightly report the app sends lands in the recipient's junk folder. Nothing
bounces. The message arrives, intact, and is filed anyway.

The partner's MX writes an `Authentication-Results` header on everything it
accepts, so for once the receiving side's opinion is readable:

```
$ send-report
sent
$ head -1 /var/mail/received/latest.eml
Authentication-Results: mx.partner.example; spf=fail smtp.mailfrom=alerts@corp.example;
  dkim=fail header.d=corp.example; dmarc=none (p=none) header.from=corp.example
```

Three verdicts, three failures, and not one of them is about the mail server.
They are all statements about DNS records for `corp.example` — a domain whose
zone this box happens to serve, in `/etc/dnsmasq.d/corp.conf`.

That is the thing worth internalising before touching anything: **mail
authentication is a DNS problem wearing a mail costume.** The sending host is
configured correctly. The domain is not.

## The three mechanisms, and what each one actually asks

They are usually recited as a list. They are not a list; they answer three
different questions and they fail in three different ways.

**SPF — was this machine allowed to send?**

The receiver takes the domain of the **envelope sender** (`MAIL FROM`, not the
`From:` header), looks up its TXT record, and asks whether the IP that just
connected is on the list.

```
$ dig +short TXT corp.example
"v=spf1 ip4:203.0.113.7 -all"
```

The mail leaves this box on `10.93.0.1`. The record names an address that has
never sent it — someone's old relay, most likely, kept after a migration. `-all`
at the end means *and nobody else*, so the answer is `fail`.

SPF proves nothing about the message. It authorises a machine, and only for the
duration of one hop: **forward the mail and SPF breaks**, because the forwarder
is now the sending IP and it is not in your record.

**DKIM — was this message signed by the domain, and is it unaltered?**

The sender signs selected headers and the body with a private key and puts the
result in the message:

```
DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/simple; d=corp.example;
 i=@corp.example; q=dns/txt; s=mail; t=1787351626; h=from : to :
 subject : date; bh=ugSQRef2XWWmVh5xRZogH7z7JiVfK2e+yEWXSLp62jU=;
 b=iLrH27tA2v6qMpcCf0s9270jJinmfxUf2/KDcRxW0677fhkrAd7ILtK5Ii5DXv0lUg1v1
```

Two tags matter here. `d=` is the signing domain and `s=` is the **selector**,
and the receiver joins them to build the name it looks the public key up at:

```
<selector>._domainkey.<domain>   →   mail._domainkey.corp.example
```

There is no such record on this domain, so the receiver has a signature and
nothing to check it with. The signature travels with the message, so unlike SPF
it survives forwarding — but any relay that rewrites a signed header or the body
(a mailing list appending a footer, for instance) breaks it.

**DMARC — do either of those belong to the address the human sees?**

SPF checks the envelope sender. DKIM checks the signing domain. Neither of them
looks at the `From:` header, which is the only address a person is shown — and
that gap is exactly what spoofing lives in. Mail can pass SPF for
`bounces.marketing-tool.example` while the `From:` says
`ceo@yourbank.example`.

DMARC closes it, with two requirements:

1. **At least one** of SPF or DKIM passes, and
2. that one is **aligned** — its domain matches the domain in `From:`.

*One*, not both, and this is deliberate: forwarding kills SPF and keeps DKIM;
a mailing list can break DKIM and keep SPF. Requiring either one means normal
mail survives normal handling.

Then the policy — `p=none`, `p=quarantine`, `p=reject` — tells the receiver what
to do when neither is aligned. `p=none` means *do nothing, just tell me*, which
is where an unconfigured domain sits and why nothing here is bouncing.

```
$ dig +short TXT _dmarc.corp.example
```

Nothing. No record, no policy, `dmarc=none`, and the filter is left to guess —
which it does, unfavourably.

## Your objective

Three things.

1. Make one message authenticate on all three:

   ```
   spf=pass  dkim=pass  dmarc=pass
   ```

   Everything is published in DNS. `/opt/mail` is shipped and checksummed — do
   not edit the sender or the receiver.

2. Publish a DMARC policy that asks for something. `p=none` is where the domain
   already is.

3. Write `/root/answers/mail.md`, exactly two lines:

   ```
   dkim_record_name: <the DNS name the receiver looks up for the key>
   dmarc_needs: <how many of SPF and DKIM must pass and align: one or both>
   ```

## What you're being graded on

A message the receiver authenticated itself, on all three, with a DMARC policy
of `quarantine` or `reject` and an SPF record that still ends in `-all` — a
record that authorises everybody passes SPF by abandoning it, and is not a fix.

<details>
<summary>Hint 1 — publishing a TXT record with dnsmasq</summary>

```
txt-record=corp.example,"v=spf1 ip4:10.93.0.1 -all"
```

`systemctl restart dnsmasq` after editing, then read it back the way the
receiver will:

```
$ dig +short TXT corp.example @10.93.0.1
```

If `dig` does not show it, nothing downstream will either. Records that were
never served are the most common outcome of this exercise.

</details>

<details>
<summary>Hint 2 — turning the signing key into a record</summary>

The record carries the public key as one base64 string, without the PEM armour
and without newlines:

```
$ openssl rsa -in /etc/mail/dkim/mail.private -pubout 2>/dev/null \
    | grep -v '^-' | tr -d '\n'
```

Publish it as:

```
txt-record=mail._domainkey.corp.example,"v=DKIM1; k=rsa; p=<that base64>"
```

The name comes from the signature's own `s=` and `d=` tags. This key is 1024-bit
so the whole record fits inside one 255-character DNS string; a 2048-bit key does
not, and has to be published as two quoted strings that the receiver
concatenates.

</details>

<details>
<summary>Hint 3 — reading the verdict after every change</summary>

```
$ send-report
$ head -1 /var/mail/received/latest.eml
$ cat /var/mail/received/verdicts.log
```

Change one record, send one message, read one header. Changing all three and
sending once tells you only that something is still wrong.

</details>

## What actually happened

Three separate omissions, of the kind that accumulate rather than get decided:

- **SPF named an old relay.** The record was right when it was written. The
  sending host moved and the record did not, which is the single most common SPF
  fault — and it is invisible until somebody's filter starts caring.
- **DKIM was never published.** The application was configured to sign, and
  signing works without the DNS side existing. Nothing on the sending end can
  tell you the key is missing; only a receiver can.
- **DMARC did not exist.** So the domain had no policy, the recipient's filter
  had nothing to bind the `From:` header to, and it made its own decision.

The reason this is filed as a mail-server ticket every single time is that the
symptom appears in mail, the tool everyone reaches for is the mail log, and the
mail log says the message was delivered — successfully, to the spam folder.

<details>
<summary>Solution</summary>

```
$ pub=$(openssl rsa -in /etc/mail/dkim/mail.private -pubout 2>/dev/null \
        | grep -v '^-' | tr -d '\n')

$ cat >> /etc/dnsmasq.d/corp.conf <<DNS
txt-record=mail._domainkey.corp.example,"v=DKIM1; k=rsa; p=$pub"
txt-record=_dmarc.corp.example,"v=DMARC1; p=reject; rua=mailto:dmarc@corp.example"
DNS

$ sed -i 's/ip4:203.0.113.7/ip4:10.93.0.1/' /etc/dnsmasq.d/corp.conf
$ systemctl restart dnsmasq
```

Then send one and read the header:

```
$ send-report
sent
$ head -1 /var/mail/received/latest.eml
Authentication-Results: mx.partner.example; spf=pass smtp.mailfrom=alerts@corp.example;
  dkim=pass header.d=corp.example; dmarc=pass (p=reject) header.from=corp.example
```

```
dkim_record_name: mail._domainkey.corp.example
dmarc_needs: one
```

In production, `p=reject` is where you finish, not where you start: publish
`p=none` with an `rua=` address first, read the aggregate reports until every
legitimate sender is accounted for, then tighten. Going straight to reject on a
domain you do not fully know the senders of is how the invoices stop arriving.

</details>

## Carrying this forward

- **All three live in DNS.** If mail is being filed and not bounced, read the
  records before you read the mail log.
- **SPF authorises a host; DKIM authenticates a message.** Forwarding breaks the
  first and mailing lists break the second, which is why DMARC accepts either.
- **DMARC is the only one that mentions the `From:` header** anybody sees. Without
  it, SPF and DKIM can both pass for a domain that is not the one being read.
- **The selector is in the signature.** `s=` and `d=` build the record name; you
  never have to guess it.
- **Test from the receiving side.** `Authentication-Results` is the verdict.
  Anything you conclude from the sending host is a hypothesis.
- **Roll DMARC out in the order none → quarantine → reject**, watching the
  aggregate reports at each step.

That is the last of the hands-on lessons in this module. What is left is the
drill: one symptom, a cause seeded at a different layer every run, and no hint
about which one — the whole of modules 04 and 05 with the labels taken off.
