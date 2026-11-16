#!/bin/sh
# Writes devops/checkout's delivery history: commits on main, and the deploy
# tags the pipeline left behind. Module 25 measures this history, so it is
# deterministic — the same profile always produces the same commits, times and
# tags, and the graders recompute their answers from what it wrote.
#
#   seed.sh <profile> <repo-url>
#
# Profiles:
#   base        twelve weeks from Mon 2026-07-06: a Tue/Thu release train,
#               hotfixes, two aborted deploys, a change-freeze week
#   gamed       base, then six more weeks of a Thursday-only train and a
#               nightly redeploy of whatever production already runs
#   methodical  twelve weeks of a Wednesday-only train
#
# Every deploy is an annotated tag deploy/<environment>/<run>, dated when the
# deploy ran. Release tags v1.<week>.0 mark builds, not deploys.
#
# Runs under busybox sh: it is executed inside the ci-stack sops container.
set -eu

profile=$1
url=$2

case "$profile" in
  base|gamed|methodical) ;;
  *) echo "unknown profile: $profile" >&2; exit 2 ;;
esac

T0=1783296000 # Mon 2026-07-06 00:00 UTC
DAY=86400
weeks=12
[ "$profile" = gamed ] && weeks=18

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q -b main "$work/r"
cd "$work/r"
mkdir -p src ops

at() {
  GIT_AUTHOR_DATE="$1 +0000"
  GIT_COMMITTER_DATE="$1 +0000"
  export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
}

# commit <epoch> <area> <subject> [body]
authors="ana bo chen dev"
ncommit=0
commit() {
  ncommit=$((ncommit + 1))
  set -- "$@" ""
  who=$(echo $authors | cut -d' ' -f$((ncommit % 4 + 1)))
  at "$1"
  printf '// %s\n' "$3" >> "src/$2.js"
  git add -A
  if [ -n "$4" ]; then
    git -c user.name="$who" -c user.email="$who@example.invalid" commit -q -m "$3" -m "$4"
  else
    git -c user.name="$who" -c user.email="$who@example.invalid" commit -q -m "$3"
  fi
  last=$(git rev-parse HEAD)
}

short() { git rev-parse --short=12 "$1"; }
subject_of() { git log -1 --format=%s "$1"; }

# deploy <epoch> <environment> <result> <target> <trigger>
run=400
deploy() {
  run=$((run + 1))
  at "$1"
  git -c user.name=pipeline -c user.email=pipeline@example.invalid \
    tag -a "deploy/$2/$run" "$4" \
    -m "deploy checkout to $2" \
    -m "environment: $2
commit: $4
run: $run
trigger: $5
result: $3"
}

# Routine work. Some of it says "fix", none of it fixes anything a customer saw.
routine_work="cart|feat(cart): remember the last delivery address
ui|refactor(ui): split the basket component
api|chore(api): log request ids on every response
search|perf(search): reuse the tokenizer between queries
docs|docs: describe the release train in the README
pricing|test(pricing): cover vouchers that expire at midnight
ui|fix(ui): align the basket badge on narrow screens
orders|feat(orders): export order history as CSV
api|refactor(api): move validation into one middleware
cart|test(cart): table-driven tests for quantity limits
checkout|feat(checkout): remember the chosen payment method
deps|chore(deps): bump the test runner
search|feat(search): suggest categories while typing
orders|refactor(orders): one query for the order summary
docs|docs: runbook entry for a stuck payment
ui|fix(ui): typo in the empty-basket message
pricing|refactor(pricing): name the rounding rule
api|feat(api): rate-limit the guest checkout endpoint
cart|perf(cart): skip recomputing totals for unchanged lines
checkout|test(checkout): end-to-end test for guest checkout"
nroutine=$(printf '%s\n' "$routine_work" | wc -l)
routine() { # <epoch>
  item=$(printf '%s\n' "$routine_work" | sed -n "$((ncommit % nroutine + 1))p")
  commit "$1" "${item%%|*}" "${item#*|}"
}

hm() { echo $(( $1 + $2 * 3600 + $3 * 60 )); }

# Fixes trailer for a commit that repairs an earlier one.
fixes() { echo "Fixes: $(short "$1") (\"$(subject_of "$1")\")"; }
reverts() { echo "This reverts commit $1."; }

commit $(hm $((T0 - 3 * DAY)) 10 0) docs "docs: checkout service"
printf 'release_train: [tue, thu]\n' > ops/cd.yaml
git add -A
at $(hm $((T0 - 3 * DAY)) 10 5)
git -c user.name=ana -c user.email=ana@example.invalid commit -q -m "ops: deploy configuration"
[ "$profile" = methodical ] && {
  printf 'release_train: [wed]\n' > ops/cd.yaml
  git add -A
  at $(hm $((T0 - 3 * DAY)) 10 10)
  git -c user.name=ana -c user.email=ana@example.invalid commit -q -m "ops: one release train a week, on Wednesday"
}

prod_target=""
w=0
while [ "$w" -lt "$weeks" ]; do
  d=0
  while [ "$d" -lt 7 ]; do
    day=$((T0 + (w * 7 + d) * DAY))
    key="$w.$d"
    q4=0
    [ "$w" -ge 12 ] && q4=1

    # The nightly redeploy, from the week it was switched on.
    if [ "$profile" = gamed ] && [ "$q4" = 1 ] && [ "$key" != 12.0 ]; then
      deploy $(hm $day 2 0) production succeeded "$prod_target" nightly
    fi

    if [ "$d" -ge 5 ]; then d=$((d + 1)); continue; fi

    if [ "$q4" = 1 ]; then
      n=$((1 + (w * 5 + d) % 2))
    else
      n=$((2 + (w * 5 + d) * 7 % 3))
    fi
    train=0
    case "$profile.$d.$q4" in
      base.1.0|base.3.0|gamed.1.0|gamed.3.0|gamed.3.1|methodical.2.0) train=1 ;;
    esac
    [ "$profile" != methodical ] && [ "$w" = 6 ] && train=0

    # --- 09:xx ---------------------------------------------------------------
    t=$(hm $day 9 $(( (w * 11 + d * 7) % 50 )))
    case "$profile.$key" in
      base.2.1|gamed.2.1) commit $t search "feat(search): fuzzy product search"; y1=$last ;;
      base.6.0|gamed.6.0) commit $t docs "docs: change freeze this week for the payment provider migration" ;;
      base.8.1|gamed.8.1) commit $t orders "feat(orders): show a delivery estimate"; x5=$last ;;
      base.11.3|gamed.11.3) commit $t deps "chore(deps): bump payment-sdk to 4.2.0"; x4=$last ;;
      gamed.12.0)
        printf 'release_train: [thu]\nnightly_redeploy: true  # keeps the CDN cache warm\n' > ops/cd.yaml
        git add -A; at $t
        git -c user.name=dev -c user.email=dev@example.invalid commit -q \
          -m "ops: Thursday release train, and redeploy production every night" \
          -m "The nightly redeploy keeps the CDN cache warm."
        ;;
      *) routine $t ;;
    esac

    # --- 10:xx: release builds, hotfixes and launches that cannot wait ---------
    if [ "$d" = 0 ]; then
      at $(hm $day 10 0)
      git -c user.name=pipeline -c user.email=pipeline@example.invalid \
        tag -a "v1.$w.0" HEAD -m "release v1.$w.0" \
        -m "Built and pushed registry.example.invalid/checkout:1.$w.0"
    fi
    case "$profile.$key" in
      base.4.2|gamed.4.2)
        deploy $(hm $day 10 30) production succeeded "$aborted" manual
        prod_target=$aborted ;;
      base.5.4|gamed.5.4)
        commit $(hm $day 10 10) cart "fix(cart): recompute cached totals when the cart changes" \
          "$(fixes "$x2")

INC-103: customers saw stale totals after removing items."
        deploy $(hm $day 10 40) production succeeded "$last" manual
        prod_target=$last ;;
      base.8.4|gamed.8.4)
        deploy $(hm $day 9 0) production succeeded "$(git rev-parse HEAD)" manual
        prod_target=$(git rev-parse HEAD) ;;
    esac

    # --- 11:xx ---------------------------------------------------------------
    t=$(hm $day 11 $(( (w * 7 + d * 13) % 50 )))
    case "$profile.$key" in
      base.2.1|gamed.2.1)
        commit $t search "fix(search): return no results for an empty query" "$(fixes "$y1")" ;;
      base.5.3|gamed.5.3) commit $t cart "feat(cart): cache cart totals for ten minutes"; x2=$last ;;
      base.8.2|gamed.8.2)
        commit $t orders "fix(orders): delivery estimate skips weekends" \
          "$(fixes "$x5")

Reported by customers: Friday orders promised for Sunday." ;;
      base.10.1|gamed.10.1) commit $t checkout "feat(checkout): new address form"; x3=$last ;;
      base.9.2|gamed.9.2) commit $t cart "fix(test): flaky timeout in cart.test.js" ;;
      *) [ "$n" -ge 2 ] && routine $t ;;
    esac

    # --- 12:00 staging --------------------------------------------------------
    staged=$(git rev-parse HEAD)
    deploy $(hm $day 12 0) staging succeeded "$staged" push

    # --- 13:xx ---------------------------------------------------------------
    t=$(hm $day 13 $(( (w * 3 + d * 17) % 50 )))
    case "$profile.$key" in
      base.1.2|gamed.1.2) commit $t pricing "feat(pricing): round discounts per line item"; x1=$last ;;
      base.10.2|gamed.10.2) commit $t api "feat(api): paginate order history"; y2=$last ;;
      base.8.3|gamed.8.3) commit $t ui "feat(banner): autumn sale banner for Friday's launch" ;;
      gamed.14.2) commit $t invoices "feat(invoices): PDF invoices"; x7=$last ;;
      methodical.6.1) commit $t invoices "feat(invoices): PDF invoices"; x7=$last ;;
      *) [ "$n" -ge 3 ] && routine $t ;;
    esac

    # --- 14:00 hotfix for a customer-reported bug -----------------------------
    case "$profile.$key" in
      base.8.2|gamed.8.2)
        deploy $(hm $day 14 0) production succeeded "$(git rev-parse HEAD)" manual
        prod_target=$(git rev-parse HEAD) ;;
    esac

    # --- 15:00 the release train ----------------------------------------------
    if [ "$train" = 1 ]; then
      case "$profile.$key" in
        base.4.1|gamed.4.1|base.9.3|gamed.9.3)
          deploy $(hm $day 15 0) production "aborted: health check failed before traffic shifted; production unchanged" "$staged" release-train
          aborted=$staged ;;
        *)
          deploy $(hm $day 15 0) production succeeded "$staged" release-train
          prod_target=$staged ;;
      esac
    fi

    # --- 16:xx ---------------------------------------------------------------
    t=$(hm $day 16 $(( (w * 13 + d * 3) % 50 )))
    case "$profile.$key" in
      base.1.3|gamed.1.3)
        commit $(hm $day 16 30) pricing "Revert \"feat(pricing): round discounts per line item\"" \
          "$(reverts "$x1")

INC-101: order totals off by a cent on multi-item orders."
        deploy $(hm $day 16 45) production succeeded "$last" manual
        prod_target=$last ;;
      base.10.2|gamed.10.2)
        commit $t api "fix(api): page size off by one" "$(fixes "$y2")" ;;
      base.9.3|gamed.9.3)
        deploy $(hm $day 16 20) production succeeded "$aborted" manual
        prod_target=$aborted ;;
      base.11.3|gamed.11.3)
        commit $(hm $day 16 40) deps "Revert \"chore(deps): bump payment-sdk to 4.2.0\"" \
          "$(reverts "$x4")

INC-106: 3-D Secure card payments failing."
        deploy $(hm $day 16 55) production succeeded "$last" manual
        prod_target=$last ;;
      gamed.14.3|methodical.6.2)
        commit $(hm $day 16 30) invoices "Revert \"feat(invoices): PDF invoices\"" \
          "$(reverts "$x7")

Invoice downloads timing out for every customer."
        deploy $(hm $day 16 45) production succeeded "$last" manual
        prod_target=$last ;;
      *) [ "$n" -ge 4 ] && routine $t ;;
    esac

    # --- 17:xx ---------------------------------------------------------------
    case "$profile.$key" in
      base.10.1|gamed.10.1)
        commit $(hm $day 17 5) checkout "fix(checkout): accept postcodes with spaces" \
          "$(fixes "$x3")

INC-105: the new address form rejected postcodes with spaces."
        deploy $(hm $day 17 30) production succeeded "$last" manual
        prod_target=$last ;;
    esac

    d=$((d + 1))
  done
  w=$((w + 1))
done

# The forge is reset to exactly this: main, and these tags.
api=http://forge:3000/api/v1
auth="-u devops:devopslings"
repo=devops/checkout
for rule in $(curl -fsS $auth "$api/repos/$repo/branch_protections" 2>/dev/null \
                | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
  curl -fsS $auth -X DELETE "$api/repos/$repo/branch_protections/$rule" >/dev/null 2>&1 || true
done
if ! curl -fsS $auth "$api/repos/$repo" >/dev/null 2>&1; then
  curl -fsS $auth -X POST "$api/user/repos" -H 'Content-Type: application/json' \
    -d '{"name":"checkout","auto_init":false,"default_branch":"main","private":false}' >/dev/null
fi

git push -q --force --prune "$url" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
echo "seeded $profile: $(git rev-list --count HEAD) commits, $(git tag -l 'deploy/*' | wc -l | tr -d ' ') deploy tags"
