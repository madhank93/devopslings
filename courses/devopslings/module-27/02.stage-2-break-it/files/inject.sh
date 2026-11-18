#!/usr/bin/env bash
# Before every check: the parts of the environment the drawn fault is
# replayed in go back to their starting point. Nothing the student owns is
# touched, so this succeeds whatever they changed.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/common.sh"

case "$(drawn_fault)" in
  health) pricing_up ;;
esac
echo "fault armed"
