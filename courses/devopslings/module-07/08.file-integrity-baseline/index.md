---
kind: lesson
title: "the integrity monitor that cried deploy"
description: |
  A file-integrity monitor took a baseline and now reports sixteen changed
  files. Fifteen are today's release rewriting the app; one is a NOPASSWD:ALL
  line an intruder slipped into sudoers — invisible in the noise. The monitor is
  watching the one directory guaranteed to change on every deploy, so its report
  is useless exactly when it matters. The fix is scope: watch what should stay
  still, not what is built to move.
name: file-integrity-baseline
slug: file-integrity-baseline
createdAt: "2026-08-26"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # ---- clean slate -------------------------------------------------------
      rm -rf /etc/fim /var/lib/fim /srv/app /usr/local/bin/fim-check \
             /usr/local/bin/app-helper /etc/app.conf /etc/sudoers.d/appdeploy \
             /root/answers/fim.md
      install -d /etc/fim /var/lib/fim /srv/app/current /root/answers

      # ---- the files worth watching: stable system state ---------------------
      echo 'listen = 0.0.0.0:8080' > /etc/app.conf
      printf '#!/bin/sh\necho "app-helper v1"\n' > /usr/local/bin/app-helper
      chmod 0755 /usr/local/bin/app-helper
      echo 'appdeploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart app.service' \
          > /etc/sudoers.d/appdeploy
      chmod 0440 /etc/sudoers.d/appdeploy

      # ---- the deployed application: changes on every release ----------------
      for i in $(seq 1 15); do
        echo "asset $i build-100" > /srv/app/current/asset$i.js
      done

      # ---- the integrity monitor, watching everything including the app ------
      #
      # watch.list names the paths hashed into the baseline. It includes the deploy
      # directory, which is the flaw the lesson turns on: that directory changes every
      # release, so it fills the report with expected churn.
      printf '%s\n' \
        /etc/app.conf \
        /usr/local/bin/app-helper \
        /etc/sudoers.d/appdeploy \
        /srv/app/current > /etc/fim/watch.list

      # fim-check hashes every file named in watch.list and reports the ones whose
      # hash differs from the baseline. It is deliberately simple — a real deployment
      # uses AIDE or Tripwire — but the logic is the same: compare now to a trusted
      # snapshot.
      cat > /usr/local/bin/fim-check <<'CHK'
      #!/bin/bash
      base=/var/lib/fim/baseline.sha256
      files() { while read -r p; do [ -n "$p" ] && find "$p" -type f 2>/dev/null; done < /etc/fim/watch.list | sort -u; }
      files | while read -r f; do
        cur=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
        old=$(awk -v f="$f" '$2==f{print $1}' "$base")
        if [ -z "$old" ]; then
          echo "NEW      $f"
        elif [ "$cur" != "$old" ]; then
          echo "CHANGED  $f"
        fi
      done
      CHK
      chmod 0755 /usr/local/bin/fim-check

      # ---- the trusted baseline, taken before today's release ----------------
      { while read -r p; do [ -n "$p" ] && find "$p" -type f 2>/dev/null; done \
          < /etc/fim/watch.list | sort -u | while read -r f; do
          echo "$(sha256sum "$f" | cut -d' ' -f1)  $f"
        done; } > /var/lib/fim/baseline.sha256

      # ---- today: a release, and an intrusion hidden inside it ---------------
      #
      # The release rewrites every app asset — expected, legitimate. In the same
      # window someone appends a blanket NOPASSWD rule to the sudoers drop-in — not
      # expected, and the thing the monitor exists to catch. Against the current
      # watch list it is one line in sixteen.
      for i in $(seq 1 15); do
        echo "asset $i build-101" > /srv/app/current/asset$i.js
      done
      echo 'appdeploy ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/appdeploy

      cat > /root/questions.txt <<'Q'
      A file-integrity monitor watches this box. It took a baseline of hashes, and
      fim-check reports every watched file that no longer matches:

        $ fim-check
        CHANGED  /etc/sudoers.d/appdeploy
        CHANGED  /srv/app/current/asset1.js
        CHANGED  /srv/app/current/asset2.js
        ... (fifteen more) ...

      Sixteen changes. Fifteen are today's release rewriting the application assets —
      entirely expected, and they will happen again tomorrow. One is not: someone
      appended `appdeploy ALL=(ALL) NOPASSWD: ALL` to /etc/sudoers.d/appdeploy, a
      full root grant. It is buried in the release noise, and on a busy box nobody
      reads sixteen lines every deploy — so nobody sees it.

      An integrity baseline is only useful if a real change stands out. Watching a
      directory that is supposed to change on every release guarantees it never will.
      Fix the monitor so its report shows the unexpected change and not the deploy:
      stop watching the directory whose whole job is to change, and leave the stable
      system paths under watch.

        /etc/fim/watch.list   the paths hashed into the baseline
        fim-check             re-run it to see the report

      Do not re-take the baseline over the current state — that would bake today's
      intrusion in as the new "known good". The fix is what you watch, not when you
      snapshot.

      Then write /root/answers/fim.md with exactly two lines:

        tampered_file: <the file the monitor should have made obvious>
        stopped_watching: <the directory you removed from the watch list>
      Q

      echo "scenario ready — fim-check drowns one intrusion in fifteen expected deploy changes"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/fim.md
      deploydir=/srv/app
      tampered=/etc/sudoers.d/appdeploy

      if [ ! -x /usr/local/bin/fim-check ]; then
        echo "not yet: /usr/local/bin/fim-check is missing — the scenario did not"
        echo "         initialise cleanly."
        exit 1
      fi

      report=$(/usr/local/bin/fim-check 2>/dev/null || true)

      # The report must no longer be full of the deploy directory. Watching a
      # path that changes every release is the flaw; the report should be signal.
      if printf '%s\n' "$report" | grep -q "$deploydir"; then
        n=$(printf '%s\n' "$report" | grep -c "$deploydir")
        echo "not yet: fim-check still reports $n change(s) under $deploydir."
        echo "         That directory is rewritten on every deploy, so watching it"
        echo "         guarantees noise. Remove it from /etc/fim/watch.list — its"
        echo "         integrity is the release pipeline's job, not the host FIM's."
        exit 1
      fi

      # And it must still catch the intrusion. If the report is empty the monitor
      # was blinded — either the watch list was emptied or the baseline was
      # re-taken over the tampered state.
      if ! printf '%s\n' "$report" | grep -q "$tampered"; then
        echo "not yet: fim-check no longer flags $tampered, which still holds the"
        echo "         injected 'NOPASSWD: ALL' line."
        if ! grep -q "$tampered" /etc/fim/watch.list 2>/dev/null; then
          echo "         You stopped watching it — but that file is exactly the kind"
          echo "         of stable system path a baseline is for. Only the deploy"
          echo "         directory should have come off the list."
        else
          echo "         If you re-took the baseline, you recorded the intrusion as"
          echo "         known-good. Restore a baseline from before the tampering;"
          echo "         the fix is what you watch, not when you snapshot."
        fi
        exit 1
      fi

      # The written summary.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/fim.md is missing or empty."
        echo "         Two lines: tampered_file and stopped_watching."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_tam=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*tampered_file[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_stop=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*stopped_watching[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_tam" | grep -q 'appdeploy'; then
        echo "not yet: tampered_file says '${a_tam:-nothing}'. Name the file that"
        echo "         got the unexpected change — the sudoers drop-in."
        exit 1
      fi
      if ! printf '%s' "$a_stop" | grep -q '/srv/app'; then
        echo "not yet: stopped_watching says '${a_stop:-nothing}'. Name the deploy"
        echo "         directory you removed from the watch list."
        exit 1
      fi

      echo "PASS — the deploy churn is out of the report and the sudoers tamper is"
      echo "       the one thing fim-check now shows. A baseline that survives a"
      echo "       release is one that never watched what a release changes."
