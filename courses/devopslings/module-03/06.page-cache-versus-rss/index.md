---
kind: lesson
title: "the service that is leaking 200 MB, except for the part that is not"
description: |
  catalog-api's memory climbs all day and never comes down. Most of what the
  monitoring is counting is not the application's memory at all and will be
  handed back the moment anything needs it. Underneath that, there is a real
  leak, and it is much smaller.
name: page-cache-versus-rss
slug: page-cache-versus-rss
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv/catalog /var/lib/devopslings /root/answers

      # A catalogue the service re-reads on every cycle. Reading it fills the
      # page cache, which is charged to the cgroup and counted by anything
      # looking at memory.current.
      dd if=/dev/urandom of=/srv/catalog/catalog.dat bs=1M count=180 status=none

      cat > /usr/local/bin/catalog-api <<'PY'
      #!/usr/bin/env python3
      import time

      # The genuine leak: one 256 KiB buffer retained per cycle, for no reason.
      # Small next to the page cache, and it is the half that never comes back.
      leaked = []
      cycles = 0

      while True:
          with open("/srv/catalog/catalog.dat", "rb") as f:
              while f.read(4 * 1024 * 1024):
                  pass

          leaked.append(bytearray(256 * 1024))
          cycles += 1
          with open("/srv/catalog/.cycles", "w") as c:
              c.write(str(cycles))
          time.sleep(0.5)
      PY
      chmod 0755 /usr/local/bin/catalog-api

      cat > /etc/systemd/system/catalog-api.service <<'UNIT'
      [Unit]
      Description=Catalog API

      [Service]
      ExecStart=/usr/local/bin/catalog-api
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable catalog-api.service >/dev/null 2>&1 || true
      systemctl restart catalog-api.service >/dev/null 2>&1 || true
      sleep 15

      echo file > /var/lib/devopslings/mem.reclaimable

      cat > /root/questions.txt <<'Q'
      catalog-api's memory keeps climbing. The graph the team is watching reads
      memory.current for the unit's cgroup, and it has gone from 40M to over
      200M since this morning.

        /root/answers/reclaimable   which part of that the kernel will hand back
                                    under pressure, without the process doing
                                    anything. One of:

                                      anon   anonymous memory (heap, stacks)
                                      file   page cache backing files on disk
                                      slab   kernel objects
                                      none   all of it is the application's

      Then fix the actual leak. The check runs the service through two rounds of
      work and requires the non-reclaimable part to stay flat between them.

      catalog-api must keep re-reading /srv/catalog/catalog.dat every cycle —
      that read is its job, not the bug.
      Q

      icg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value catalog-api.service 2>/dev/null)"
      echo "scenario ready — catalog-api cgroup memory.current is $(( $(cat "$icg/memory.current" 2>/dev/null || echo 0) / 1024 / 1024 ))M and climbing"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want=$(cat /var/lib/devopslings/mem.reclaimable)

      # Ask systemd where the unit's cgroup actually is rather than assuming
      # system.slice — the path moves with slice configuration, and a wrong path
      # would make every measurement below silently read zero.
      cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value catalog-api.service 2>/dev/null)"

      if [ ! -s /root/answers/reclaimable ]; then
        echo "not yet: /root/answers/reclaimable is missing or empty"
        echo "         one of: anon, file, slab, none"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/reclaimable | tr 'A-Z' 'a-z')
      if [ "$got" != "$want" ]; then
        case "$got" in
          anon)
            echo "not yet: anonymous memory is the heap — there is nothing on disk to"
            echo "         reconstruct it from, so the kernel cannot simply drop it. The"
            echo "         most it can do is swap it out, which moves the memory rather"
            echo "         than reclaiming it, and costs the job every page on the way"
            echo "         back."
            ;;
          slab)
            echo "not yet: slab is kernel objects — inodes, dentries and so on. Some of it"
            echo "         is reclaimable, and it is not where 180M went. Look at the split"
            echo "         in $cg/memory.stat."
            ;;
          none)
            echo "not yet: read $cg/memory.stat and add up the two largest lines. One of"
            echo "         them is a copy of a file that already exists on disk."
            ;;
          *)
            echo "not yet: '$got' is not one of anon, file, slab, none"
            ;;
        esac
        exit 1
      fi

      if ! systemctl is-active --quiet catalog-api.service; then
        echo "not yet: catalog-api.service is not running"
        exit 1
      fi

      # The read must still happen — "stop reading the file" is not the fix.
      if ! grep -q 'catalog.dat' /usr/local/bin/catalog-api; then
        echo "not yet: catalog-api no longer reads /srv/catalog/catalog.dat"
        echo "         that read is the service's job. The page cache it produces was"
        echo "         never the problem."
        exit 1
      fi

      if [ ! -r "$cg/memory.stat" ]; then
        echo "not yet: cannot read $cg/memory.stat — reset the lesson"
        exit 1
      fi

      cycles() { cat /srv/catalog/.cycles 2>/dev/null || echo 0; }
      anon_now() {
        # No fallback to zero: an unreadable stat file must fail the check, not
        # quietly report no growth.
        awk '/^anon /{print $2; found=1} END {if (!found) exit 1}' "$cg/memory.stat"
      }

      # Round one.
      c0=$(cycles)
      for _ in $(seq 1 60); do
        [ "$(cycles)" -ge $(( c0 + 12 )) ] && break
        sleep 0.5
      done
      if ! a1=$(anon_now); then
        echo "not yet: could not read anonymous memory from $cg/memory.stat"
        exit 1
      fi

      # Round two, same amount of work again.
      c1=$(cycles)
      for _ in $(seq 1 60); do
        [ "$(cycles)" -ge $(( c1 + 12 )) ] && break
        sleep 0.5
      done
      if ! a2=$(anon_now); then
        echo "not yet: could not read anonymous memory from $cg/memory.stat"
        exit 1
      fi

      if [ "$(cycles)" -le "$c0" ]; then
        echo "not yet: catalog-api is not completing cycles — it has to keep working"
        exit 1
      fi

      growth=$(( (a2 - a1) / 1024 / 1024 ))
      if [ "$growth" -gt 4 ]; then
        echo "not yet: anonymous memory grew ${growth}M across the second round of work"
        echo "         ($(( a1 / 1024 / 1024 ))M -> $(( a2 / 1024 / 1024 ))M)."
        echo "         That is the half the kernel cannot reclaim, and it is still"
        echo "         proportional to how much work has been done. The page cache is"
        echo "         not what is growing here."
        exit 1
      fi

      file_bytes=$(awk '/^file /{print $2}' "$cg/memory.stat")
      file_mb=$(( ${file_bytes:-0} / 1024 / 1024 ))
      echo "PASS — reclaimable part correctly identified as $want (${file_mb}M of page"
      echo "       cache), and anonymous memory held flat at $(( a2 / 1024 / 1024 ))M across two rounds."
---
