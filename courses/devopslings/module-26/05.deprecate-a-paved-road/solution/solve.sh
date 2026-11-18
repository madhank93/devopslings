#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Move each consumer on a branch first, merge only what is green there, fix
# what v2 turns red on its branch, and leave bin/v1-consumers behind.
set -euo pipefail

docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'SOLVE'
set -euo pipefail
api="http://forge:3000/api/v1"
auth="-u devops:devopslings"
base="http://devops:devopslings@forge:3000/devops"
work=$(mktemp -d)

status() {
  local s=""
  for _ in $(seq 1 100); do
    s=$(curl -s $auth "${api}/repos/devops/$1/commits/$2/status" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
    case "$s" in success|failure|error) break ;; esac
    sleep 3
  done
  printf '%s' "$s"
}

# The check first: it lists who has to move.
git clone -q "${base}/paved-road.git" "$work/pr"
cd "$work/pr"
git config user.email devops@example.invalid
git config user.name devops
mkdir -p bin
cat > bin/v1-consumers <<'SH'
#!/usr/bin/env bash
# Lists every repository on the forge with a workflow that uses paved-road@v1.
# Exits 1 when there is any. Needs FORGE_URL, FORGE_USER, FORGE_PASSWORD.
set -euo pipefail
auth=(-u "${FORGE_USER}:${FORGE_PASSWORD}")
found=0
page=1
while :; do
  repos=$(curl -fsS "${auth[@]}" "${FORGE_URL}/api/v1/repos/search?limit=50&page=${page}" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).data.map(r=>r.full_name).join("\n")))')
  [ -n "$repos" ] || break
  for r in $repos; do
    files=$(curl -fsS "${auth[@]}" "${FORGE_URL}/api/v1/repos/${r}/contents/.forgejo/workflows" 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).map(f=>f.path).join("\n"))}catch{}})' || true)
    for f in $files; do
      body=$(curl -fsS "${auth[@]}" "${FORGE_URL}/api/v1/repos/${r}/raw/${f}" || true)
      if grep -qE 'paved-road@v1\b' <<<"$body"; then
        echo "${r}: ${f}"
        found=1
      fi
    done
  done
  page=$((page + 1))
done
[ "$found" = 0 ] && echo "no repository uses paved-road@v1"
exit "$found"
SH
chmod +x bin/v1-consumers
git add -A
git commit -qm "bin/v1-consumers: who is still on v1"
git push -q origin HEAD:main

export FORGE_URL=http://forge:3000 FORGE_USER=devops FORGE_PASSWORD=devopslings
consumers=$(bin/v1-consumers | sed -n 's|^devops/\([^:]*\):.*|\1|p' | sort -u || true)

# Every consumer moves on a branch; the branch's pipeline is the canary.
for n in $consumers; do
  git clone -q "${base}/${n}.git" "$work/$n"
  (cd "$work/$n"
    git config user.email devops@example.invalid
    git config user.name devops
    git checkout -q -b paved-road-v2
    sed -i -E 's/paved-road@v1\b/paved-road@v2/' .forgejo/workflows/*
    git commit -qam "build with paved-road@v2"
    git push -q origin paved-road-v2)
done
for n in $consumers; do
  cd "$work/$n"
  if [ "$(status "$n" "$(git rev-parse HEAD)")" != success ]; then
    # v2 found what v1 hid: fix the code the test caught, still on the branch.
    sed -i 's/sum + i.price,/sum + i.price * i.qty,/' src/cart.js
    git commit -qam "cart: count quantity in total"
    git push -q origin paved-road-v2
    [ "$(status "$n" "$(git rev-parse HEAD)")" = success ] || { echo "${n} still red on its branch" >&2; exit 1; }
  fi
  git push -q origin paved-road-v2:main
  git push -q origin --delete paved-road-v2
done
for n in $consumers; do
  [ "$(status "$n" "$(git -C "$work/$n" rev-parse HEAD)")" = success ] || { echo "${n} not green on main" >&2; exit 1; }
done

cd "$work/pr" && bin/v1-consumers
SOLVE
