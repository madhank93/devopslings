---
title: "The API key is baked into the image"
---

## The situation

`greeter` calls a weather partner's API. The partner gave you a key, and the
key went where it was quickest to put it, the Dockerfile:

```dockerfile
ENV PARTNER_API_KEY=wxp_live_4be1c09f7d2a4e38b6513c8e0f9a27d5
```

It works. It is also readable by anyone who can do any of these:

- pull the image: `docker image inspect` prints every `ENV`
- run `docker inspect` on the host, or read `/proc/1/environ` in the container
- read the repository the Dockerfile lives in

Every registry the image was pushed to has a copy, and so does every machine
that pulled it. None of them can be cleaned up from here.

## Your objectives

1. Store the key in OpenBao at `secret/greeter/partner-api`, in a field called
   `key`.
2. Change greeter to fetch it from OpenBao when it starts.
3. Leave the key in no file, no image layer and no environment.

## Getting set up

The code is in `scratch/store-and-read/`: a `Dockerfile` and `app.py`.

OpenBao runs in the stack at <http://localhost:8200>. The root token is
`devopslings-root`, and the UI is at <http://localhost:8200/ui>. The `bao` CLI
is in the `bao` container, so a shell function saves typing:

```
bao() { docker exec -i -e BAO_TOKEN="${BAO_TOKEN:-devopslings-root}" devopslings-ci-stack-bao-1 bao "$@"; }
bao kv list secret/
```

greeter already has its own OpenBao token, in `sandboxes/ci-stack/.env` as
`GREETER_BAO_TOKEN`. It can read `secret/greeter/*` and nothing else. Inside
the container it arrives as `BAO_TOKEN`, next to `BAO_ADDR`.

Rebuild and restart greeter from `sandboxes/ci-stack`:

```
docker compose up -d --build greeter
curl localhost:18160/status
```

## What you're being graded on

- OpenBao holds the key at `secret/greeter/partner-api`.
- The key is not in greeter's environment: not the image's `ENV`, and not the
  container's.
- No file in the running container holds it. No layer of the image holds it,
  and nothing in the build history does.
- No file in `sandboxes/ci-stack` or `scratch/store-and-read` holds it.
- `GET /status` reports the key's fingerprint. Leave that endpoint as it is.
- greeter does not use the root token.
- The value really comes from OpenBao. The check writes a different value to
  OpenBao, restarts greeter, and expects the new fingerprint. Then it puts the
  real key back.

<details>
<summary>Hint 1 — putting the key in</summary>

`secret/` is a KV version 2 engine. Write and read it with `bao kv`:

```
bao kv put secret/greeter/partner-api key=wxp_live_4be1c09f7d2a4e38b6513c8e0f9a27d5
bao kv get secret/greeter/partner-api
```

Typing it on the command line puts it in your shell history. `bao kv put
secret/greeter/partner-api key=-` reads the value from stdin instead.

</details>

<details>
<summary>Hint 2 — reading it from Python</summary>

OpenBao is an HTTP API. A KV v2 read is a GET on `/v1/secret/data/<path>`,
with the token in a header. The value sits two levels down, because KV v2
wraps it with version metadata:

```
curl -s -H "X-Vault-Token: $BAO_TOKEN" $BAO_ADDR/v1/secret/data/greeter/partner-api
{"data":{"data":{"key":"wxp_live_…"},"metadata":{"version":1,…}},…}
```

`urllib.request` and `json` are all `load_key()` needs.

</details>

<details>
<summary>Hint 3 — the check says a layer holds it</summary>

Each `RUN`, `COPY` and `ADD` makes a layer, and an image is every one of its
layers. `RUN rm key.txt` adds a layer that hides the file. The layer that added
it is still there. Build args are recorded too: `docker history --no-trunc`
prints them.

The only image that does not contain the key is one that never had it. Rebuild
from a Dockerfile that never mentions it.

</details>

<details>
<summary>Solution</summary>

Store the key:

```
bao kv put secret/greeter/partner-api key=wxp_live_4be1c09f7d2a4e38b6513c8e0f9a27d5
```

In `app.py`, fetch it instead of reading the environment:

```python
import urllib.request

def load_key():
    req = urllib.request.Request(
        os.environ["BAO_ADDR"] + "/v1/secret/data/greeter/partner-api",
        headers={"X-Vault-Token": os.environ["BAO_TOKEN"]})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)["data"]["data"]["key"]
```

Delete the `ENV PARTNER_API_KEY=…` line from the Dockerfile, then:

```
docker compose up -d --build greeter
curl localhost:18160/status
```

### Where the key lives now

It is in OpenBao's storage, encrypted. It is in greeter's memory while greeter
runs. It is nowhere else. Rebuild the image, push it, hand it to a contractor:
there is nothing in it to find.

This also changes what a leak means. Before, the key was in every copy of the
image, so rotating it meant rebuilding and redeploying everything. Now you
change one value in OpenBao and restart greeter.

### The token is still in the environment

greeter needs *something* to log in to OpenBao with, and here that is a token
in `BAO_TOKEN`. This is the "secret zero" problem: every scheme starts with one
credential the app is simply given.

The token is still better than the key, because it is narrower. It can read
`secret/greeter/*` and nothing else. It can be revoked without telling the
partner. And OpenBao can log every read made with it. On a real platform the
token comes from the platform's identity instead: a Kubernetes service account,
a cloud instance role. Then even secret zero is not a value anyone typed.

### Why not just an environment variable from compose?

That is the most common fix, and the check rejects it. The value leaves the
image, which is real progress. But `docker inspect` still prints it, a crash
dump or a debug endpoint that prints `os.environ` still includes it, and child
processes inherit it. An environment variable is a file with a different name.

</details>
