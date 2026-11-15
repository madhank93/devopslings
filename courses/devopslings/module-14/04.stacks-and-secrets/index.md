---
kind: lesson
title: "prod needs a password, and the program only knows dev"
description: |
  notify is deployed from one program to one environment, with a password
  read from whoever's shell runs pulumi up. Give it a dev and a prod stack
  from the same program, with per-stack config and a password that is
  encrypted in the repository and in state.
name: stacks-and-secrets
slug: stacks-and-secrets
createdAt: "2026-11-13"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      rm -rf /root/notify /root/handoff /var/lib/pulumi/notify
      install -d /root/notify /root/handoff /var/lib/pulumi/notify /var/lib/devopslings
      rnd() { head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
      dev_pw="nfy_dev_$(rnd)" prod_pw="nfy_prod_$(rnd)"
      printf 'dev=%s\nprod=%s\n' "$dev_pw" "$prod_pw" > /var/lib/devopslings/stacks-and-secrets.pw
      chmod 600 /var/lib/devopslings/stacks-and-secrets.pw

      # The handoff from the mail team: outside the repository, on purpose.
      printf 'port=8025\nsmtp_password=%s\n' "$dev_pw" > /root/handoff/dev.txt
      printf 'port=2525\nsmtp_password=%s\n' "$prod_pw" > /root/handoff/prod.txt

      cd /root/notify
      cp /opt/pulumi-template/go.mod /opt/pulumi-template/go.sum .
      sed -i 's/^module program$/module notify/' go.mod
      cat > Pulumi.yaml <<'YAML'
      name: notify
      runtime: go
      description: the notification relay
      backend:
        url: file:///var/lib/pulumi/notify
      YAML
      cat > main.go <<'GO'
      package main

      import (
      	"os"

      	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
      )

      func main() {
      	pulumi.Run(func(ctx *pulumi.Context) error {
      		// Export SMTP_PASSWORD before running pulumi up.
      		password := os.Getenv("SMTP_PASSWORD")
      		_, err := docker.NewContainer(ctx, "notify", &docker.ContainerArgs{
      			Name:  pulumi.String("notify"),
      			Image: pulumi.String("busybox:1.37.0"),
      			Envs: pulumi.StringArray{
      				pulumi.String("PORT=8025"),
      				pulumi.String("SMTP_PASSWORD=" + password),
      			},
      			Command: pulumi.ToStringArray([]string{"sh", "-c", `echo notify > /www/index.html; exec httpd -f -p "$PORT" -h /www`}),
      		})
      		return err
      	})
      }
      GO
      git init -q
      git add -A
      git commit -qm "notify: deploy the relay"

      pulumi stack init dev --non-interactive >/dev/null 2>&1
      SMTP_PASSWORD="$dev_pw" pulumi up -s dev --yes --non-interactive >/dev/null

      cat > /root/handoff/README <<'TXT'
      notify runs in dev only, as a container called notify, and the password
      comes from whoever exports SMTP_PASSWORD before pulumi up.

      Make /root/notify deploy both environments from one program:

        - two stacks, dev and prod. Each stack's port and SMTP password are
          stack config: notify:port and notify:smtpPassword. The values are in
          /root/handoff/dev.txt and prod.txt.
        - each stack runs one container, notify-<stack name>, with PORT and
          SMTP_PASSWORD in its environment, serving on PORT
        - neither password appears in plaintext anywhere in the repository,
          in any commit, or in either stack's state
        - the stack config files are committed
        - nothing in the program depends on the stack being called dev or prod;
          a third stack must work from its config alone
      TXT
      echo "scenario ready — notify runs in dev only; read /root/handoff/README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      pwf=/var/lib/devopslings/stacks-and-secrets.pw
      if [ ! -s "$pwf" ] || ! cd /root/notify 2>/dev/null || [ ! -d .git ]; then
        echo "not yet: /root/notify or its git repository is gone — reset the lesson"
        exit 1
      fi
      dev_pw=$(sed -n 's/^dev=//p' "$pwf") prod_pw=$(sed -n 's/^prod=//p' "$pwf")

      # A stack left over from an earlier run of this check.
      cleanup() {
        cd /root/notify
        pulumi destroy -s check --yes --non-interactive >/dev/null 2>&1 || true
        pulumi stack rm check --yes --force --non-interactive >/dev/null 2>&1 || true
        rm -f /root/notify/Pulumi.check.yaml
      }
      cleanup
      trap cleanup EXIT

      # ---- 1. the repository -----------------------------------------------------
      for pw in "$dev_pw" "$prod_pw"; do
        hits=$(grep -rlF --exclude-dir=.git -- "$pw" . 2>/dev/null || true)
        if [ -n "$hits" ]; then
          echo "not yet: a password is in plaintext in the working tree:"
          sed 's|^\./|           |' <<<"$hits"
          if grep -q 'Pulumi\..*\.yaml' <<<"$hits"; then
            echo "         in a stack config file it was set without --secret:"
            echo "         pulumi config set --secret notify:smtpPassword ... stores it encrypted"
          fi
          exit 1
        fi
        # grep -c reads to the end: grep -q would close the pipe early, and
        # pipefail would turn git log's SIGPIPE into "no match".
        n=$(git log --all -p 2>/dev/null | grep -cF -- "$pw" || true)
        if [ "${n:-0}" -gt 0 ]; then
          echo "not yet: a password is in a commit. Removing it in a later commit leaves it in"
          echo "         history, which every clone gets. Rewrite the commit that added it."
          exit 1
        fi
      done
      for s in dev prod; do
        # A plain `pulumi config set` of a secret-looking value is refused, which
        # leaves a config file with the port and no password, never committed.
        if [ -f "Pulumi.$s.yaml" ] && ! grep -q 'notify:smtpPassword:' "Pulumi.$s.yaml"; then
          echo "not yet: Pulumi.$s.yaml has no notify:smtpPassword. Set it encrypted:"
          echo "         pulumi config set -s $s --secret notify:smtpPassword ..."
          echo "         Without --secret, Pulumi refuses a value that looks like a password"
          echo "         rather than store it in plaintext."
          exit 1
        fi
        if ! git ls-files --error-unmatch "Pulumi.$s.yaml" >/dev/null 2>&1; then
          echo "not yet: Pulumi.$s.yaml is not committed. Stack config is part of the program:"
          echo "         without it, nobody else can deploy $s"
          exit 1
        fi
        if ! git diff --quiet HEAD -- "Pulumi.$s.yaml" 2>/dev/null; then
          echo "not yet: Pulumi.$s.yaml has changes that are not committed"
          exit 1
        fi
        if ! grep -Eq '^[[:space:]]+notify:smtpPassword:[[:space:]]*$' "Pulumi.$s.yaml" \
          || ! grep -A1 -E '^[[:space:]]+notify:smtpPassword:' "Pulumi.$s.yaml" | grep -q 'secure:'; then
          echo "not yet: Pulumi.$s.yaml has no encrypted notify:smtpPassword (a 'secure:' value)"
          exit 1
        fi
        if ! grep -Eq '^[[:space:]]+notify:port:' "Pulumi.$s.yaml"; then
          echo "not yet: Pulumi.$s.yaml has no notify:port"
          exit 1
        fi
      done

      # ---- 2. what runs ------------------------------------------------------------
      if ! out=$(go build -o /dev/null . 2>&1); then
        echo "not yet: the program does not build:"
        grep -m3 -E '\.go:[0-9]+' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      # runs <container> <port> <password> <what>: prints what is wrong with it.
      runs() {
        local j
        j=$(docker inspect "$1" 2>/dev/null) || { echo "there is no container called $1 — is $4 deployed?"; return; }
        [ "$(jq -r '.[0].State.Running' <<<"$j")" = true ] || echo "$1 is not running"
        jq -e --arg e "PORT=$2" '.[0].Config.Env | index($e)' <<<"$j" >/dev/null || echo "$1 does not have PORT=$2"
        jq -e --arg e "SMTP_PASSWORD=$3" '.[0].Config.Env | index($e)' <<<"$j" >/dev/null || echo "$1 does not have $4's SMTP password"
        [ "$(docker exec "$1" wget -qO- -T 3 "http://127.0.0.1:$2/" 2>/dev/null || true)" = notify ] || echo "$1 does not answer on port $2"
      }
      for row in "dev 8025 $dev_pw" "prod 2525 $prod_pw"; do
        set -- $row
        bad=$(runs "notify-$1" "$2" "$3" "the $1 stack")
        if [ -n "$bad" ]; then
          echo "not yet: the $1 stack:"
          sed 's/^/           /' <<<"$bad"
          exit 1
        fi
        if ! st=$(pulumi stack export -s "$1" --non-interactive 2>/dev/null); then
          echo "not yet: there is no $1 stack"
          exit 1
        fi
        if grep -qF -- "$3" <<<"$st"; then
          echo "not yet: the $1 stack's state holds the password in plaintext. The config value is"
          echo "         encrypted, but the program read it as an ordinary string, so Pulumi no"
          echo "         longer knows it is secret. Read it with RequireSecret, which keeps it an"
          echo "         Output marked secret all the way into the container's env"
          exit 1
        fi
      done
      if docker inspect notify >/dev/null 2>&1; then
        echo "not yet: the old container called notify is still running beside notify-dev"
        exit 1
      fi

      # ---- 3. a stack the program has never heard of -------------------------------
      chk_pw="nfy_check_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      if ! out=$( { pulumi stack init check --non-interactive \
                 && pulumi config set -s check notify:port 2626 \
                 && pulumi config set -s check --secret notify:smtpPassword "$chk_pw" \
                 && pulumi up -s check --yes --non-interactive; } 2>&1); then
        echo "not yet: a third stack, check, with only notify:port and notify:smtpPassword set,"
        echo "         fails to deploy:"
        grep -m3 'error:' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      bad=$(runs notify-check 2626 "$chk_pw" "the check stack")
      if [ -n "$bad" ]; then
        echo "not yet: a third stack, check, deployed with its own port and password, is wrong:"
        sed 's/^/           /' <<<"$bad"
        echo "         does the program choose values by the stack's name instead of reading its config?"
        exit 1
      fi

      echo "PASS — dev and prod come from one program and their own config, and the password"
      echo "       is encrypted in the repository and in state."
---
