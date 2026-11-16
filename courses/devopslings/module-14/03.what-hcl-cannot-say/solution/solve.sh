#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/edge

cat > sites.go <<'GO'
package main

import (
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// buildSite adds a site's lb and cache, and its webs beyond web-0.
// Logical names come from the site name, never its position in the list.
func buildSite(ctx *pulumi.Context, s Site, net *docker.Network) error {
	webs := []string{s.Name + "-web-0"}
	for i := 1; i < s.Replicas; i++ {
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
GO

# Call it after web-0 in main.go's loop.
sed -i 's|^\t\t\tif _, err := container(ctx, s.Name+"-web-0", net, "SITE="+s.Name); err != nil {|\t\t\tif err := buildSite(ctx, s, net); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n&|' main.go
gofmt -w main.go sites.go
go build -o /dev/null .
pulumi up -s dev --yes --non-interactive
