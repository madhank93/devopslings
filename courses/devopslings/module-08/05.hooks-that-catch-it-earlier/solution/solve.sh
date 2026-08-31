#!/bin/sh
set -e

cat >.git/hooks/pre-commit <<'HOOK'
#!/bin/sh
# Scan the staged change, not the working tree: the developer's own .env holds a
# real token and is never committed, so a working-tree scan blocks every commit.
if git diff --cached -U0 | grep -qE '^\+.*pgw_live_[0-9a-f]{32}'; then
  echo "pre-commit: staged changes add a gateway credential (pgw_live_...)." >&2
  echo "            Remove it and read it from the environment instead." >&2
  exit 1
fi
HOOK
chmod +x .git/hooks/pre-commit

cat >rationale.md <<'RATIONALE'
no_verify: git commit --no-verify skips every pre-commit hook, so the check is advisory
shared: no — .git/hooks is not part of the repository and git clone does not copy it
backstop: the same pattern has to run server-side, in CI and in push protection on the forge
RATIONALE
