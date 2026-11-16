---
title: "three sites, three shapes, one input"
---

## The situation

`/root/edge` deploys edge sites. The list of sites is stack config, in
`Pulumi.dev.yaml`:

```yaml
config:
  edge:sites:
    - name: eu
      replicas: 3
      cache: true
    - name: us
      replicas: 1
      cache: false
```

Each site should get its own network and a different shape of containers. A
site with several replicas needs a load balancer in front of them, and only
some sites want a cache. Today the program loops over the sites and builds
one web container each, whatever the config says.

In HCL this is where `count = var.replicas > 1 ? 1 : 0` and nested `for_each`
over flattened maps begin. In Go it is an `if` and a `for`. Go makes this part
easy. It also brings back a trap from module 13 in a new form. Pulumi matches
each resource to its state by its logical name, the string you pass as the
first argument to `New...`. Take that name from a position in a list and you
have rebuilt `count`. Insert a site at the front and every site after it is
renamed, so Pulumi destroys and recreates it.

## Your objectives

1. For every site in `edge:sites`, on its own network `edge-<site>`, build:
   - `<site>-web-0` to `<site>-web-<replicas-1>`, each with `SITE=<site>`
   - `<site>-lb`, only when replicas is more than 1, with
     `UPSTREAMS=<site>-web-0 <site>-web-1 ...` (every web, in order)
   - `<site>-cache`, only when cache is true, with no extra env
2. Nothing else. A site with one replica and no cache is just `<site>-web-0`.
3. When the site list changes, a site that did not change must not be
   replaced, wherever it sits in the list.

## What you're being graded on

The grader writes its own site lists into `Pulumi.dev.yaml` and runs
`pulumi up` after each:

- `eu` with 3 replicas and a cache, then `us` with 1 replica and no cache
- `ap` with 2 replicas and a cache, then `eu` with 1 replica and no cache.
  `eu` has moved down the list and shrunk. Its `eu-web-0` and network must
  be the same objects as before.
- a single site, `solo`, with 1 replica and a cache

After each `up`, every container's name, network and `SITE`/`UPSTREAMS` must
be exactly what the config asks for, with nothing missing and nothing extra.
Then it puts your own `Pulumi.dev.yaml` back and deploys it.

<details>
<summary>Hint 1 — reading the shape</summary>

The program already reads the config into `[]Site`, and the `container`
helper builds one container. What is left is ordinary Go:

```go
for i := 0; i < s.Replicas; i++ { ... }
if s.Replicas > 1 { ... }
if s.Cache { ... }
```

Collect the web names in a slice as you go, and `strings.Join` them for the
load balancer's `UPSTREAMS`.

</details>

<details>
<summary>Hint 2 — what makes a name stable</summary>

A logical name is the resource's identity in state. Two runs that give a
resource the same logical name mean "the same resource". A different logical
name means "delete that one, create this one".

So derive each name from what the resource *is*, like `eu-web-0` or `eu-lb`,
and never from where it was in the list. `for i, s := range sites` is fine,
as long as `i` never reaches a name.

</details>

<details>
<summary>Hint 3 — when it fails anyway</summary>

The containers also have fixed Docker names. If a logical name moves, Pulumi
creates the new resource before it deletes the old one, and Docker refuses a
second container called `eu-web-0`. So an unstable name usually shows up as a
name conflict on `pulumi up`, not as a quiet replacement. `pulumi preview
--diff` after changing the list shows which resources it would create and
delete, before anything does.

</details>

<details>
<summary>Solution</summary>

A `buildSite` function, called in the loop in place of the single web:

```go
func buildSite(ctx *pulumi.Context, s Site, net *docker.Network) error {
	var webs []string
	for i := 0; i < s.Replicas; i++ {
		name := fmt.Sprintf("%s-web-%d", s.Name, i)
		if _, err := container(ctx, name, net, "SITE="+s.Name); err != nil {
			return err
		}
		webs = append(webs, name)
	}
	if s.Replicas > 1 {
		if _, err := container(ctx, s.Name+"-lb", net, "UPSTREAMS="+strings.Join(webs, " ")); err != nil {
			return err
		}
	}
	if s.Cache {
		if _, err := container(ctx, s.Name+"-cache", net); err != nil {
			return err
		}
	}
	return nil
}
```

Every logical name comes from the site's name and the container's role.
Nothing comes from a position.

### What HCL cannot say, and what it can

HCL can build all of this. It takes `count` on a conditional, a `for_each`
over a map built with `flatten`, and a `join` inside a `for` expression, and
the next reader has to run it in their head. In Go it is the loop you would
write anyway. Identity is the same in both tools. It belongs to what a
resource is, not to where it happened to be in a list.

</details>
