#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cat > /root/decisions/answers.txt <<'ANS'
case-1: tool=opentofu because=readers
case-2: tool=pulumi because=embedding
case-3: tool=neither because=mutation
case-4: tool=pulumi because=reuse
case-5: tool=either because=backend
ANS
