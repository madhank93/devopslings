---
title: "port 443 is open, and HTTP/3 cannot get through it"
---

## The situation

`shop.lab` moved to a new edge proxy last week. It speaks HTTP/1.1, HTTP/2 and
HTTP/3. This box is the router and firewall in front of it, and the `mobile`
namespace is a client out on the internet.

Ordinary HTTPS works:

```
$ ip netns exec mobile curl -s --cacert /root/shop-ca.crt https://shop.lab/
shop-answers-2026 HTTP/2.0
```

The mobile team's new SDK speaks only HTTP/3, and it can't connect at all:

```
$ ip netns exec mobile curl -sS -m 5 --http3-only --cacert /root/shop-ca.crt https://shop.lab/
curl: (28) Connection timed out after 5003 milliseconds
```

From inside the web tier, HTTP/3 works, so the proxy is fine:

```
$ ip netns exec web curl -s --http3-only --cacert /root/shop-ca.crt https://shop.lab/
shop-answers-2026 HTTP/3.0
```

And the firewall has allowed 443 for years.

## Your objective

Make the HTTP/3-only client work, and keep it working after a reboot. Every
other UDP port into the web tier, including the internal service on 9999,
stays shut.

## What you're being graded on

HTTP/3 and HTTP/2 from `mobile` both reach `shop.lab`. UDP 9999 on the web tier
doesn't answer from outside. `/etc/edge-fw.nft`, loaded into an empty
namespace, produces exactly the ruleset that's running.

<details>
<summary>Hint 1: what HTTP/3 runs on</summary>

HTTP/1.1 and HTTP/2 run over TCP. HTTP/3 doesn't: it runs over **QUIC**, a
transport built on **UDP**. QUIC does its own handshakes, retransmission and
congestion control in user space, and carries TLS 1.3 inside. So "port 443" now
means two different ports: TCP 443 and UDP 443.

The proxy even says so. Every HTTP/2 response carries an offer:

```
$ ip netns exec mobile curl -sI --cacert /root/shop-ca.crt https://shop.lab/ | grep -i alt-svc
alt-svc: h3=":443"; ma=2592000
```

That means "I also speak HTTP/3 on port 443", on UDP.

</details>

<details>
<summary>Hint 2: read the chain in order</summary>

```
$ nft list chain inet edge to_web
table inet edge {
	chain to_web {
		ct state established,related accept
		tcp dport { 80, 443 } accept
		meta l4proto udp counter packets 4 bytes 4912 drop
		counter packets 0 bytes 0 drop
	}
}
```

Follow a QUIC packet through it, top to bottom. The first rule that decides
wins, and nothing after it is consulted.

</details>

<details>
<summary>Hint 3: where a new rule goes</summary>

`nft add rule` appends to the **end** of a chain, after the drop that already
caught the packet. `nft insert rule` puts it at the top. Whichever you use,
the running ruleset and `/etc/edge-fw.nft` are two separate things.
`edge-fw.service` loads the file at boot.

</details>

## Why "allow 443" was true

For years, everything on 443 was TCP, so `tcp dport { 80, 443 } accept` meant
"allow HTTPS". The rule below it, which drops all UDP, was written after a
reflection flood, by someone who was right at the time that nothing behind the
firewall spoke UDP.

The new proxy does. Each QUIC handshake is a UDP datagram to port 443. It skips
the TCP rule because it isn't TCP, and lands on the UDP drop. The drop counter
goes up by one per attempt, and the client sees silence until it times out.

Browsers hide this. They learn about HTTP/3 from `alt-svc` over an HTTP/2
connection, try QUIC, and fall back to TCP when it doesn't answer, so the site
feels fine. A client that only speaks HTTP/3 has nothing to fall back to.

## The fix

<details>
<summary>Solution</summary>

Accept UDP 443 before the blanket UDP drop, in the boot file, and reload it:

```
		# HTTP and HTTPS
		tcp dport { 80, 443 } accept

		# HTTP/3 (QUIC)
		udp dport 443 accept

		# INC-1907: UDP reflection flood against the web tier.
		meta l4proto udp counter drop
```

```
$ systemctl reload edge-fw.service
$ ip netns exec mobile curl -s --http3-only --cacert /root/shop-ca.crt https://shop.lab/
shop-answers-2026 HTTP/3.0
```

The file starts with `destroy table inet edge`, so reloading replaces the table
instead of adding a second copy of every rule.

</details>

## What not to do

**`nft add rule inet edge to_web udp dport 443 accept`.** It lands after the UDP
drop and never matches. The command succeeded and the rule is there, but
nothing changes.

**Delete the UDP drop.** The final `counter drop` still catches QUIC, so it
still fails. Delete that too and port 9999 is open to the flood the firewall
was written for.

**Fix the running ruleset and stop.** HTTP/3 works until the next boot, when
`edge-fw.service` loads the old file.

**Turn off HTTP/3 on the proxy.** Browsers stop trying, and the client this
ticket is about stops working entirely.

## Carrying this forward

When a firewall rule names a port, check which protocol it names. QUIC moved the
web's main port onto UDP, and many rulesets were written when 443 was only
TCP. VPNs (WireGuard on UDP 51820), DNS and video calls fail in the same way,
silently, with HTTP/2 or TCP working fine next to them.

In an ordered chain the first rule that decides wins. Adding a rule isn't
enough: put it where the packet will reach it.
