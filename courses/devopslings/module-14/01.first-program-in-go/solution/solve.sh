#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/hello

sed -i \
  -e 's|pulumi.String("unless-stoped")|pulumi.String("unless-stopped")|' \
  -e 's|pulumi.String("GREETING=hello PORT=8080")|pulumi.ToStringArray([]string{"GREETING=hello", "PORT=8080"})|' \
  main.go
gofmt -w main.go

sed -i -e 's/^compiler=.*/compiler=Envs/' -e 's/^preview=.*/preview=Restart/' -e 's/^tofu=.*/tofu=validate/' answers.txt

pulumi up --yes --non-interactive -s dev
