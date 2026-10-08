---
title: "staging ran an image nobody built"
---

## The situation

Staging is supposed to run what CI built. On Tuesday it ran this:

```console
$ docker cp shop-cart:/build.json - | tar -xO
{"service":"cart","build":"laptop, uncommitted changes"}
```

A developer with push access tested a fix by pushing straight to
`shop/cart:staging`, and the deploy pulled it like any other image. Nothing
was wrong with the deploy. It did what its trust policy says:

```json
{
  "default": [{ "type": "insecureAcceptAnything" }]
}
```

`/etc/containers/policy.json` is the trust policy that skopeo, Podman, Buildah
and CRI-O consult on every pull, and `deploy.sh` pulls through it. As written,
anything the registry returns is fine. The registry returns whatever was last
pushed by anyone who could push.

## Your objectives

1. Create a cosign key pair in `/work/keys/`.
2. Sign the CI release, `127.0.0.1:15000/shop/cart:1.2.0`.
3. Change the trust policy so that images from `127.0.0.1:15000` are accepted
   only if they carry a valid signature from your key.
4. Deploy 1.2.0 to staging with `/work/deploy/deploy.sh`.

## What you're being graded on

The grader pulls through `/etc/containers/policy.json` exactly as the deploy
does. Release 1.2.0 must be accepted, by tag and by digest. Then it pushes an
unsigned image and requires it to be refused — and then it moves the `1.2.0`
tag itself to that unsigned image, and requires the release's own name to be
refused too. It puts the tag back afterwards.

<details>
<summary>Hint 1 — signing, offline</summary>

```console
$ cd /work/keys && cosign generate-key-pair
$ crane digest 127.0.0.1:15000/shop/cart:1.2.0
```

Sign the digest rather than the tag — the signature is about content, and the
tag is the thing that might move.

This sandbox has no internet, so there is no public transparency log (Rekor) to
record the signature in, and cosign 3 refuses to skip it unless asked. It also
defaults to a newer signature format than the runtime here reads. The flags
that say both things:

```console
$ cosign sign --key cosign.key \
    --use-signing-config=false --tlog-upload=false --new-bundle-format=false \
    127.0.0.1:15000/shop/cart@sha256:…
```

Check it the way a human would: `cosign verify --key cosign.pub
--insecure-ignore-tlog 127.0.0.1:15000/shop/cart:1.2.0`. And look at what
signing added to the repository: `crane ls 127.0.0.1:15000/shop/cart`.

</details>

<details>
<summary>Hint 2 — the policy</summary>

A policy maps transports and scopes to requirements. The most specific scope
wins, and `default` is what applies when nothing else matches:

```json
{
  "default": [{ "type": "reject" }],
  "transports": {
    "docker": {
      "127.0.0.1:15000": [{ "type": "sigstoreSigned", "keyPath": "…", … }]
    }
  }
}
```

The `containers-policy.json(5)` reference documents `sigstoreSigned` and
`signedIdentity`. The policy judges the image being pulled, so the
`docker-daemon:` destination in `deploy.sh` needs no rule of its own.

</details>

<details>
<summary>Solution</summary>

```console
$ cd /work/keys
$ cosign generate-key-pair                   # empty password is fine here
$ d=$(crane digest 127.0.0.1:15000/shop/cart:1.2.0)
$ cosign sign --key cosign.key \
    --use-signing-config=false --tlog-upload=false --new-bundle-format=false \
    127.0.0.1:15000/shop/cart@$d
```

`/etc/containers/policy.json`:

```json
{
  "default": [{ "type": "reject" }],
  "transports": {
    "docker": {
      "127.0.0.1:15000": [{
        "type": "sigstoreSigned",
        "keyPath": "/work/keys/cosign.pub",
        "signedIdentity": { "type": "matchRepository" }
      }]
    }
  }
}
```

```console
$ /work/deploy/deploy.sh 127.0.0.1:15000/shop/cart:1.2.0
deployed 127.0.0.1:15000/shop/cart:1.2.0
$ /work/deploy/deploy.sh 127.0.0.1:15000/shop/cart:staging
FATA[0000] Source image rejected: A signature was required, but no signature exists
```

### The part worth remembering

**A signature binds a key to a digest.** cosign signs the manifest digest, and
stores the signature next to the image — here as a tag named
`sha256-<digest>.sig`, in newer setups as an OCI *referrer* attached to the
digest. Moving a tag cannot carry a signature with it, because the signature
was never about the tag. That is why the grader's last test fails cleanly: the
name `1.2.0` was trusted, the content behind it was not.

**Signing is half; enforcement is the other half.** A signed image pulled by a
client that does not check is exactly as safe as an unsigned one. The check has
to happen where the image is about to run, under a policy the person pushing
cannot edit: `policy.json` on a host, a Kubernetes admission controller
(Sigstore's policy-controller, Kyverno's `verifyImages`) in a cluster, or the
registry itself — Harbor can refuse to *serve* an unsigned artifact from a
project with cosign content trust switched on.

**`default: reject` is the line that makes it a policy.** Allow-listing your
registry and leaving the default at accept means an image from anywhere else
still runs. Start from reject and list what you trust.

**`signedIdentity` stops a signed image being replayed under another name.**
`matchRepository` requires the repository recorded in the signature to be the
one being pulled, so a signature for `shop/cart` does not vouch for the same
bytes copied to `shop/admin`.

**What this sandbox simplifies.** Real signing at CI scale is usually
*keyless*: the CI job's OIDC identity gets a short-lived certificate from
Fulcio, and the signature is logged in Rekor, a public transparency log, so a
signature made with a stolen identity is at least visible. Verification then
checks the certificate identity ("signed by this repository's release
workflow") instead of a key file. The flags in the hint switch all of that off
because there is no internet here; at work you would leave the transparency log
on, and the newer bundle format on wherever your verifier reads it. The trust
model — content signed by an identity, checked against a policy at the point of
use — is the same.

</details>
