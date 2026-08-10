---
kind: lesson
title: "the batch job that got nine times slower on a box with memory to spare"
description: |
  ledger-rollup used to finish in minutes. It now grinds all night on a machine
  with gigabytes free, and top shows it using barely 200 MB. The memory it is
  short of is not the machine's, and the pages it keeps waiting for are ones it
  already had.
name: swap-and-swappiness
slug: swap-and-swappiness
createdAt: "2026-08-10"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv/ledger /var/lib/devopslings /root/answers

      cat > /usr/local/bin/ledger-rollup <<'PY'
      #!/usr/bin/env python3
      # Rolls up the day's ledger. The whole ledger is touched on every pass —
      # that is what a rollup is, and it is why the working set is the ledger
      # rather than some smaller window of it.
      #
      # The order is shuffled once and then reused, because a rollup looks
      # records up by key rather than walking the file end to end. That detail
      # decides how this failure feels: read in address order, the kernel sees
      # the pattern coming and reads ahead, and a working set that does not fit
      # costs surprisingly little. Read by key, every miss is its own trip.
      import random
      import time

      LEDGER_MB = 300

      ledger = bytearray(LEDGER_MB * 1024 * 1024)
      keys = [i * 4096 for i in range(len(ledger) // 4096)]
      random.Random(20260810).shuffle(keys)
      passes = 0

      while True:
          for off in keys:
              ledger[off] = (ledger[off] + 1) & 0xff
          passes += 1
          with open("/srv/ledger/.passes", "w") as f:
              f.write(str(passes))
          time.sleep(0.01)
      PY
      chmod 0755 /usr/local/bin/ledger-rollup

      # MemoryMax is what the platform team set when they moved this job onto
      # the shared box: a limit chosen from what the job used to use, not from
      # what it has to touch. MemorySwapMax is generous, which is precisely why
      # the job is slow instead of dead — it has somewhere to put the overflow,
      # and it pays for every page on the way back.
      cat > /etc/systemd/system/ledger-rollup.service <<'UNIT'
      [Unit]
      Description=Ledger rollup

      [Service]
      ExecStart=/usr/local/bin/ledger-rollup
      Restart=always
      MemoryAccounting=yes
      MemoryMax=200M
      MemorySwapMax=2G

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable ledger-rollup.service >/dev/null 2>&1 || true
      systemctl restart ledger-rollup.service >/dev/null 2>&1 || true
      sleep 20

      echo pswpin > /var/lib/devopslings/mem.evidence
      cat /proc/sys/vm/swappiness > /var/lib/devopslings/mem.swappiness

      cat > /root/questions.txt <<'Q'
      ledger-rollup used to complete a pass in well under a second. It now takes
      several seconds per pass, on a box with gigabytes of free memory and an
      idle CPU graph. Nothing about the ledger changed.

        /root/answers/evidence      the counter in the unit cgroup's memory.stat
                                    that proves the job is paging, rather than
                                    merely being large. One of:

                                      anon      anonymous memory in use
                                      file      page cache
                                      pgfault   minor faults
                                      pswpin    pages read back in from swap

      Then make the job fast again, under the same input. The check watches the
      pass counter and requires the rate to recover.

      Two things it will not accept:

        - a smaller ledger. LEDGER_MB stays at 300; the job's work is the job.
        - a swappiness change. vm.swappiness is machine-wide here — this box
          shares it, and /proc/swaps, with the host it runs on. Writing it would
          retune every other container on the machine to fix one job.
      Q

      icg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value ledger-rollup.service 2>/dev/null)"
      echo "scenario ready — ledger-rollup has completed $(cat /srv/ledger/.passes 2>/dev/null || echo 0) passes, swapping $(( $(awk '/^pswpin /{print $2}' "$icg/memory.stat" 2>/dev/null || echo 0) * 4 / 1024 ))M back in so far"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want=$(cat /var/lib/devopslings/mem.evidence)
      swappiness_was=$(cat /var/lib/devopslings/mem.swappiness)

      # Ask systemd where the unit's cgroup is rather than assuming a slice —
      # a wrong path here would read zero for every counter below and pass the
      # lesson for the wrong reason.
      cgpath=$(systemctl show -p ControlGroup --value ledger-rollup.service 2>/dev/null)
      cg="/sys/fs/cgroup$cgpath"

      if [ ! -s /root/answers/evidence ]; then
        echo "not yet: /root/answers/evidence is missing or empty"
        echo "         one of: anon, file, pgfault, pswpin"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/evidence | tr 'A-Z' 'a-z')
      if [ "$got" != "$want" ]; then
        case "$got" in
          anon)
            echo "not yet: anon is how much anonymous memory the job holds right now."
            echo "         A job that fits in its limit and one that is thrashing against"
            echo "         it can report the same anon. Size is not motion."
            ;;
          file)
            echo "not yet: file is page cache, which is reclaimable and cheap to lose."
            echo "         This job's memory is its own heap — there is no file behind it"
            echo "         to drop and re-read."
            ;;
          pgfault)
            echo "not yet: pgfault counts minor faults, which every process takes by the"
            echo "         million just by touching memory it already has. It is high on a"
            echo "         healthy box too. Look for the counter that only moves when a"
            echo "         page has to come back from somewhere."
            ;;
          *)
            echo "not yet: '$got' is not one of anon, file, pgfault, pswpin"
            ;;
        esac
        exit 1
      fi

      if ! systemctl is-active --quiet ledger-rollup.service; then
        # A dead unit has no cgroup, so every counter below would quietly read
        # the root cgroup's numbers instead. Say why it is dead while the
        # evidence still exists.
        if [ "$(systemctl show -p Result --value ledger-rollup.service)" = "oom-kill" ]; then
          echo "not yet: ledger-rollup is being OOM-killed, and systemd has given up"
          echo "         restarting it. Taking swap away from a job whose working set"
          echo "         does not fit does not make it fit — it only turns slow into"
          echo "         dead. The job needs room for what it touches, not a different"
          echo "         place to overflow into."
        else
          echo "not yet: ledger-rollup.service is not running"
        fi
        exit 1
      fi

      if [ -z "$cgpath" ]; then
        echo "not yet: ledger-rollup.service reports no cgroup — reset the lesson"
        exit 1
      fi

      # The work must not have been shrunk to fit the limit.
      if ! grep -q '^LEDGER_MB = 300$' /usr/local/bin/ledger-rollup; then
        echo "not yet: LEDGER_MB is no longer 300."
        echo "         Making the job touch less is not making the job faster — the"
        echo "         rollup has to cover the whole ledger."
        exit 1
      fi

      # vm.swappiness is shared with the host. Changing it would work, and would
      # retune every other workload on the machine to fix this one.
      swappiness_now=$(cat /proc/sys/vm/swappiness)
      if [ "$swappiness_now" != "$swappiness_was" ]; then
        echo "not yet: vm.swappiness changed from $swappiness_was to $swappiness_now."
        echo "         That knob is machine-wide — this box shares it with its host and"
        echo "         with every other container on it. Put it back and give the job"
        echo "         the memory it actually touches."
        exit 1
      fi

      if [ ! -r "$cg/memory.stat" ]; then
        echo "not yet: cannot read $cg/memory.stat — reset the lesson"
        exit 1
      fi

      passes() { cat /srv/ledger/.passes 2>/dev/null || echo 0; }
      oom_kills() { awk '/^oom_kill /{print $2; found=1} END {if (!found) print 0}' "$cg/memory.events"; }

      k0=$(oom_kills)
      p0=$(passes)
      swp0=$(awk '/^pswpin /{print $2}' "$cg/memory.stat")

      # A ten-second window, measured after the job has reached a steady state.
      # Thrashing, it manages around 25 passes; with its working set resident,
      # around 230. The threshold sits well clear of both.
      sleep 10

      k1=$(oom_kills)
      p1=$(passes)
      swp1=$(awk '/^pswpin /{print $2}' "$cg/memory.stat")

      if [ "$k1" -gt "$k0" ]; then
        echo "not yet: the job was OOM-killed during the check ($(( k1 - k0 )) times)."
        echo "         Taking swap away from a job whose working set does not fit does"
        echo "         not make it fit. It only changes slow into dead."
        exit 1
      fi

      # A restart resets the counter, so a decrease means the job died and came
      # back rather than making progress.
      if [ "$p1" -lt "$p0" ]; then
        echo "not yet: the pass counter went backwards — ledger-rollup restarted"
        echo "         during the check."
        exit 1
      fi

      done_passes=$(( p1 - p0 ))
      swapped_mb=$(( (swp1 - swp0) * 4 / 1024 ))

      if [ "$done_passes" -lt 120 ]; then
        echo "not yet: $done_passes passes in ten seconds, with ${swapped_mb}M read back"
        echo "         from swap while the check watched."
        echo ""
        echo "         The limit on this job is not the machine's memory, which is"
        echo "         mostly free. It is the one the unit was given. Compare what the"
        echo "         job touches on every pass with"
        echo "           systemctl show -p MemoryMax ledger-rollup.service"
        exit 1
      fi

      limit=$(systemctl show -p MemoryMax --value ledger-rollup.service)
      echo "PASS — $done_passes passes in ten seconds with ${swapped_mb}M swapped in,"
      echo "       against a MemoryMax of $(( limit / 1024 / 1024 ))M and vm.swappiness left at"
      echo "       $swappiness_now for everybody else."
---
