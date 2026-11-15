---
title: "move the shop from OpenTofu to Pulumi, and keep the orders"
---

## The situation

`/root/shop/main.tf` runs the shop on OpenTofu: a network `shop`, a volume
`shop-orders`, and a container `shop-app` that mounts the volume at `/data`.
The volume holds every order the shop has taken. There is no other copy.

The team is moving to Pulumi. `/root/shop-go` has an empty Go program and a
`dev` stack waiting for it.

The first guess is to write the Go program, `tofu destroy` the old stack and
`pulumi up` the new one. The program can be perfect and the orders are still
gone: `tofu destroy` deletes the volume, and Pulumi creates an empty one with
the same name.

The second guess is to leave OpenTofu alone and `pulumi up` anyway. Now two
tools think they own the same things. The next `tofu destroy` deletes the
volume from under Pulumi.

## Your objectives

1. Describe the same network, volume and container in `/root/shop-go`.
2. Hand ownership over: the `dev` stack owns all three, and OpenTofu's state
   owns none.
3. Keep the `shop-orders` volume and the `shop` network that are running
   now. Do not destroy or recreate them.
4. Finish with a `pulumi preview` that shows no changes.

## What you're being graded on

`shop-orders` must be the original volume (same creation time), with the
orders unchanged. `shop` must be the original network (same ID). OpenTofu's
state in `/root/shop` must be empty. The program must build, and the `dev`
stack must hold the network, the volume and `shop-app`, with the IDs of the
ones running.

`shop-app` must match `main.tf`: running, restart policy, environment, network,
the volume at `/data`, the network's label, and the page it serves. The
preview must be clean, and the program may not use `IgnoreChanges` to get
there.

<details>
<summary>Hint 1 — letting go without deleting</summary>

`tofu state rm ADDRESS` removes a resource from OpenTofu's state and leaves
the real thing alone. After it, OpenTofu has forgotten the resource, so no
later plan or destroy will touch it. It is module 13's `state rm`, used for
what it is for.

</details>

<details>
<summary>Hint 2 — adopting instead of creating</summary>

`pulumi.Import` is a resource option. It tells Pulumi that the resource
already exists, with this ID, and to adopt it:

```go
docker.NewVolume(ctx, "orders", &docker.VolumeArgs{
	Name: pulumi.String("shop-orders"),
}, pulumi.Import(pulumi.ID("shop-orders")))
```

A volume's ID is its name, and a network's is its full ID from
`docker network inspect -f '{{.Id}}' shop`. As with `tofu import`, the
arguments must describe the object exactly, or `pulumi up` stops with an
error naming the difference. Once the import has been applied, the option
does nothing, and you can remove it.

</details>

<details>
<summary>Hint 3 — the container</summary>

The docker provider cannot read a container's environment, networks or
mounts back from Docker, so an imported container always differs from its
code. That was true in module 13 too.

But the container holds nothing. Remove it with `docker rm -f shop-app` once
OpenTofu has forgotten it, and let Pulumi create a new one. Import what holds
data. Recreate what does not.

</details>

<details>
<summary>Solution</summary>

OpenTofu lets go first:

```
$ cd /root/shop
$ tofu state rm docker_container.app docker_network.shop docker_volume.orders
$ docker rm -f shop-app
$ docker network inspect -f '{{.Id}}' shop
```

`/root/shop-go/main.go`, with the network ID from that last command:

```go
pulumi.Run(func(ctx *pulumi.Context) error {
	net, err := docker.NewNetwork(ctx, "shop", &docker.NetworkArgs{
		Name: pulumi.String("shop"),
		Labels: docker.NetworkLabelArray{
			docker.NetworkLabelArgs{Label: pulumi.String("team"), Value: pulumi.String("shop")},
		},
	}, pulumi.Import(pulumi.ID("<network id>")))
	if err != nil {
		return err
	}
	orders, err := docker.NewVolume(ctx, "orders", &docker.VolumeArgs{
		Name: pulumi.String("shop-orders"),
	}, pulumi.Import(pulumi.ID("shop-orders")))
	if err != nil {
		return err
	}
	_, err = docker.NewContainer(ctx, "app", &docker.ContainerArgs{
		Name:    pulumi.String("shop-app"),
		Image:   pulumi.String("busybox:1.37.0"),
		Restart: pulumi.String("unless-stopped"),
		Envs:    pulumi.ToStringArray([]string{"SHOP_ENV=prod"}),
		Command: pulumi.ToStringArray([]string{"sh", "-c",
			"echo shop $SHOP_ENV > /www/index.html; exec httpd -f -p 8080 -h /www"}),
		NetworksAdvanced: docker.ContainerNetworksAdvancedArray{
			docker.ContainerNetworksAdvancedArgs{Name: net.Name},
		},
		Volumes: docker.ContainerVolumeArray{
			docker.ContainerVolumeArgs{VolumeName: orders.Name, ContainerPath: pulumi.String("/data")},
		},
	})
	return err
})
```

```
$ cd /root/shop-go
$ pulumi up --yes
    = 2 imported
    + 1 created
$ pulumi preview --expect-no-changes
```

### The order matters

Every step here is safe on its own, and the order is what keeps the orders.
Forget in OpenTofu first, so there is never a moment when a destroy in the
old tool can reach the volume. Import in Pulumi before anything is created,
so there is never a moment when Pulumi thinks the volume is new. Moving
between IaC tools is not a rewrite of the code. It is a handover of state,
one resource at a time.

</details>
