#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/notify

cat > main.go <<'GO'
package main

import (
	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		port := cfg.RequireInt("port")
		// RequireSecret keeps the value marked secret, so state stores it encrypted.
		password := cfg.RequireSecret("smtpPassword")
		_, err := docker.NewContainer(ctx, "notify", &docker.ContainerArgs{
			Name:  pulumi.String("notify-" + ctx.Stack()),
			Image: pulumi.String("busybox:1.37.0"),
			Envs: pulumi.StringArray{
				pulumi.Sprintf("PORT=%d", port),
				pulumi.Sprintf("SMTP_PASSWORD=%s", password),
			},
			Command: pulumi.ToStringArray([]string{"sh", "-c", `echo notify > /www/index.html; exec httpd -f -p "$PORT" -h /www`}),
		})
		return err
	})
}
GO

pulumi stack init prod --non-interactive
for s in dev prod; do
  port=$(sed -n 's/^port=//p' /root/handoff/$s.txt)
  pw=$(sed -n 's/^smtp_password=//p' /root/handoff/$s.txt)
  pulumi config set -s "$s" notify:port "$port"
  pulumi config set -s "$s" --secret notify:smtpPassword "$pw"
  pulumi up -s "$s" --yes --non-interactive
done

git add main.go Pulumi.dev.yaml Pulumi.prod.yaml
git commit -qm "notify: dev and prod stacks, password as a secret"
