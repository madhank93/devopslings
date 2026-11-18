---
kind: lesson
title: "How often does this repository actually ship?"
description: |
  Twelve weeks of checkout's history, and a quarterly review that wants one
  number: deployments. The repository holds three kinds of tag and several
  hundred commits, and only some of them are a change reaching production.
  Count them, and say what you counted.
name: count-your-deploys
slug: count-your-deploys
createdAt: "2026-11-16"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      work="$DEVOPSLINGS_ROOT/scratch/count-your-deploys"

      docker compose -p devopslings-ci-stack exec -T sops sh -s -- base \
        http://devops:devopslings@forge:3000/devops/checkout.git < "$module/files/seed.sh"

      rm -rf "$work"
      mkdir -p "$work"
      cat > "$work/answer.txt" <<'TXT'
      # How many deployments did checkout make in the history on the forge?
      # One key per line. The check reads the numbers and the words.

      # A whole number.
      deployments=

      # What you counted as one deployment.
      counted=

      # Every kind of thing in the repository you looked at and did not count,
      # and why it is not a deployment.
      excluded=
      TXT

      echo "scenario ready — twelve weeks of checkout, commits and tags, on the forge"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  your answer:  $work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      ans="$DEVOPSLINGS_ROOT/scratch/count-your-deploys/answer.txt"
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing — reset the lesson to put the template back."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ans" | tail -1; }

      truth=$(docker compose -p devopslings-ci-stack exec -T sops sh -s -- \
        http://devops:devopslings@forge:3000/devops/checkout.git deploys < "$module/files/metrics.sh")
      want=$(printf '%s\n' "$truth" | grep -c . || true)
      if [ "$want" -lt 10 ]; then
        echo "not yet: could not read checkout's deploy history from the forge — reset the lesson."
        exit 1
      fi

      got=$(val deployments | tr -dc '0-9')
      if [ -z "$got" ]; then
        echo "not yet: deployments= is empty. Count, then write the whole number."
        exit 1
      fi
      if [ "$got" != "$want" ]; then
        tags=$(git ls-remote --tags http://devops:devopslings@127.0.0.1:3000/devops/checkout.git 2>/dev/null | grep -v '\^{}' || true)
        n_tags=$(printf '%s\n' "$tags" | grep -c 'refs/tags/' || true)
        n_staging=$(printf '%s\n' "$tags" | grep -c 'refs/tags/deploy/staging/' || true)
        n_release=$(printf '%s\n' "$tags" | grep -c 'refs/tags/v' || true)
        all_prod=$(printf '%s\n' "$tags" | grep -c 'refs/tags/deploy/production/' || true)
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        git clone -q --bare http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r" 2>/dev/null || true
        n_commits=$(git -C "$work/r" rev-list --count HEAD 2>/dev/null || echo x)
        echo "not yet: deployments=$got, and that is not the number of times a change reached production."
        case "$got" in
          "$all_prod")
            echo "         That is every deploy/production tag. Read a few of them — git tag -n9 'deploy/production/*' —"
            echo "         and look for the ones whose result line says production was never changed." ;;
          "$n_tags"|"$((n_tags - n_release))")
            echo "         That is every deploy tag in the repository, and one environment of them is not production." ;;
          "$n_staging"|"$((n_staging + all_prod))"|"$((n_staging + want))")
            echo "         That includes deploy/staging/*. Staging is where a change is tried, not where it ships." ;;
          "$n_release")
            echo "         That is the v1.N.0 release tags. A release tag marks a build; read where it says it went." ;;
          "$n_commits")
            echo "         That is the number of commits on main. Most deploys carry several commits, and"
            echo "         some commits have not been deployed at all yet." ;;
          *)
            echo "         Start from the tags: git tag -l, then read the message of one of each kind." ;;
        esac
        exit 1
      fi

      counted=$(val counted)
      excluded=$(val excluded)
      if [ -z "$counted" ]; then
        echo "not yet: the number is right and counted= is empty. A deployment count that does not say"
        echo "         what a deployment is cannot be compared with next quarter's."
        exit 1
      fi
      missing=""
      printf '%s\n' "$excluded" | grep -Eiq '\bstaging\b' || missing="$missing staging deploys,"
      printf '%s\n' "$excluded" | grep -Eiq '\b(abort|aborted|aborts|failed|unchanged)\b' || missing="$missing aborted production deploys,"
      printf '%s\n' "$excluded" | grep -Eiq '\b(release|releases|v1|builds?|built)\b' || missing="$missing release tags,"
      if [ -n "$missing" ]; then
        echo "not yet: the number is right, and excluded= does not say what happened to:${missing%,}."
        echo "         Each of those is in the repository and looks like a deploy to somebody. Say why it is not one."
        exit 1
      fi

      echo "PASS — $want deployments over twelve weeks, $(awk "BEGIN { printf \"%.1f\", $want / 12 }") a week, and the answer says what was left out."
---
