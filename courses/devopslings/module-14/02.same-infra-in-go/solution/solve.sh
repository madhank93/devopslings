#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# OpenTofu forgets the resources without touching them.
cd /root/shop
tofu state rm docker_container.app docker_network.shop docker_volume.orders

# The container holds no data, and the provider cannot read its env, networks
# or mounts back, so it is replaced rather than imported.
docker rm -f shop-app >/dev/null
net=$(docker network inspect -f '{{.Id}}' shop)

cd /root/shop-go
cat > main.go <<GO
package main

import (
	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		net, err := docker.NewNetwork(ctx, "shop", &docker.NetworkArgs{
			Name: pulumi.String("shop"),
			Labels: docker.NetworkLabelArray{
				docker.NetworkLabelArgs{Label: pulumi.String("team"), Value: pulumi.String("shop")},
			},
		}, pulumi.Import(pulumi.ID("$net")))
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
			Command: pulumi.ToStringArray([]string{"sh", "-c", "echo shop \$SHOP_ENV > /www/index.html; exec httpd -f -p 8080 -h /www"}),
			NetworksAdvanced: docker.ContainerNetworksAdvancedArray{
				docker.ContainerNetworksAdvancedArgs{Name: net.Name},
			},
			Volumes: docker.ContainerVolumeArray{
				docker.ContainerVolumeArgs{VolumeName: orders.Name, ContainerPath: pulumi.String("/data")},
			},
		})
		return err
	})
}
GO
gofmt -w main.go
pulumi up -s dev --yes --non-interactive

# Imported once; the import options would only get in the way from now on.
sed -i -E 's/, pulumi\.Import\(pulumi\.ID\("[^"]*"\)\)\)/)/' main.go
gofmt -w main.go
pulumi preview -s dev --non-interactive --expect-no-changes
