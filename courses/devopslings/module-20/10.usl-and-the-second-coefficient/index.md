---
kind: lesson
title: "Six benchmark runs, one capacity plan"
description: |
  The indexer cluster has to be sized for the catalog relaunch, and the budget
  buys six benchmark runs. Fit the Universal Scalability Law to them, predict
  where the cluster peaks and how fast it goes there, and let one run you did
  not pay for say whether the prediction holds.
name: usl-and-the-second-coefficient
slug: usl-and-the-second-coefficient
createdAt: "2026-11-16"

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.usl-and-the-second-coefficient
      lesson=$1
      mkdir -p answers
      rm -f answers/usl.txt
      echo "scenario ready — benchmark the indexer from sandboxes/chaos-stack with:"
      echo "  bash $lesson/files/bench.sh 1 2 4 8 16 32"
      echo "Write your fit and prediction in answers/usl.txt."

  verify_done:
    timeout_seconds: 180
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.usl-and-the-second-coefficient
      lesson=$1
      ans=answers/usl.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' \r' || true; }
      num() { awk -v v="$1" 'BEGIN { exit !(v ~ /^-?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) }'; }
      s=$(field sigma); k=$(field kappa); pn=$(field peak_nodes); px=$(field peak_per_s)
      tell=$(grep -E '^cannot_tell=' "$ans" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      for v in "$s" "$k" "$pn" "$px"; do
        if ! num "$v"; then
          echo "not yet: $ans needs sigma=, kappa=, peak_nodes=, peak_per_s= (numbers) and"
          echo "cannot_tell=<a sentence>, one per line."
          exit 1
        fi
      done
      if awk -v k="$k" 'BEGIN { exit !(k <= 0) }'; then
        echo "not yet: kappa=$k. With no coherency term this is Amdahl's law, which says throughput"
        echo "levels off and never falls — but 32 nodes measured slower than 16. Something costs more"
        echo "for every node added, and that is what kappa measures. Fit both coefficients at once."
        exit 1
      fi
      if awk -v s="$s" 'BEGIN { exit !(s < 0 || s >= 1) }'; then
        echo "not yet: sigma=$s. sigma is the share of the work that only one node can do at a"
        echo "time, so it lies between 0 and 1."
        exit 1
      fi
      bench() {
        docker compose exec -T checkout sh -c 'mkdir -p /srv/usl && cat > /srv/usl/bench.py' < "$lesson/files/bench.py" 2>/dev/null || true
        docker compose exec -T -w /srv/usl checkout timeout 60 python3 bench.py "$1" 2>/dev/null | jq -r '.per_s' 2>/dev/null || true
      }
      usl() { awk -v l="$1" -v n="$2" -v s="$s" -v k="$k" 'BEGIN { printf "%.1f", l * n / (1 + s * (n - 1) + k * n * (n - 1)) }'; }
      one=$(bench 1)
      if [ -z "$one" ]; then
        echo "not yet: the benchmark did not run. Is the chaos-stack up? Try bash $lesson/files/bench.sh 1"
        exit 1
      fi
      for n in 8 32; do
        got=$(bench "$n"); want=$(usl "$one" "$n")
        if awk -v g="$got" -v w="$want" 'BEGIN { exit !(g == "" || (w - g) / g > 0.1 || (g - w) / g > 0.1) }'; then
          echo "not yet: with sigma=$s and kappa=$k the law predicts $want commits a second at $n nodes,"
          echo "and this check measured ${got:-nothing}. The coefficients have to reproduce the whole"
          echo "series, the flat top and the fall after it, not only the first few runs. Fit both at once"
          echo "to all six points (Hint 1 has the straight-line form)."
          exit 1
        fi
      done
      star=$(awk -v s="$s" -v k="$k" 'BEGIN { printf "%.1f", sqrt((1 - s) / k) }')
      if awk -v p="$pn" -v x="$star" 'BEGIN { exit !(p - x > 1.5 || x - p > 1.5) }'; then
        echo "not yet: peak_nodes=$pn, but your own coefficients put the peak at sqrt((1 - sigma) / kappa)"
        echo "= $star nodes. Report the peak of the curve you fitted, not a node count read off the runs."
        exit 1
      fi
      pn=$(awk -v p="$pn" 'BEGIN { printf "%d", p + 0.5 }')
      want=$(usl "$one" "$pn")
      if awk -v x="$px" -v w="$want" 'BEGIN { exit !((x - w) / w > 0.05 || (w - x) / w > 0.05) }'; then
        echo "not yet: peak_per_s=$px, but your coefficients give $want at $pn nodes:"
        echo "X(N) = X(1) × N / (1 + sigma (N - 1) + kappa N (N - 1)), with X(1) the one-node rate."
        exit 1
      fi
      got=$(bench "$pn")
      echo "this check ran the cluster at $pn nodes: ${got:-nothing} commits a second"
      if awk -v g="$got" -v x="$px" 'BEGIN { exit !(g == "" || (x - g) / g > 0.1 || (g - x) / g > 0.1) }'; then
        echo "not yet: you predicted $px commits a second at $pn nodes, more than 10% from the run."
        exit 1
      fi
      if [ "$(wc -w <<<"$tell" | tr -d ' ')" -lt 6 ] || \
         ! grep -Eqi '\b(why|cause[sd]?|which|resource|lock|latency|tail|percentiles?|extrapolat[a-z]*|outside|beyond|workload|fix)\b' <<<"$tell"; then
        echo "not yet: cannot_tell= needs a sentence on what the fitted curve does not tell you. Two"
        echo "numbers describe the shape of the curve; ask what you would still have to find out"
        echo "before changing the cluster, or before trusting the curve somewhere you did not measure."
        exit 1
      fi
      echo "PASS — the fit predicted $px commits a second at $pn nodes and the run gave $got."
---
