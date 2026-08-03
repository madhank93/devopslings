---
kind: lesson
title: "the service cannot write to its own directory"
description: |
  report-writer runs as its own user, is in the right group, and still cannot
  create a file. `chmod 777` makes the error go away and breaks the next thing
  quietly. The check creates a new file after you are done, which is where the
  difference shows up.
name: permissions-triage
slug: permissions-triage
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      # Three principals: the service that writes reports, the human process
      # that publishes them, and the shared group that is supposed to let the
      # second read what the first produced.
      groupadd -f reports

      id -u svc-report >/dev/null 2>&1 || \
        useradd --system --shell /usr/sbin/nologin --no-create-home svc-report
      id -u publisher >/dev/null 2>&1 || \
        useradd --system --shell /bin/bash --create-home publisher

      # svc-report IS in the group. This matters: the failure is not a missing
      # membership, which is the first thing everyone checks and the first
      # thing that will look fine.
      usermod -aG reports svc-report
      usermod -aG reports publisher

      rm -rf /srv/reports
      # Group has r-x. No w. A directory the service can enter and list and
      # cannot create anything in.
      install -d -o root -g reports -m 0755 /srv/reports

      cat > /usr/local/bin/write-report <<'SH'
      #!/bin/bash
      set -euo pipefail
      out=/srv/reports/report-$(date +%Y%m%dT%H%M%S).$RANDOM.csv
      printf 'generated_at,rows\n%s,%d\n' "$(date -Is)" "$((RANDOM % 500 + 100))" > "$out"
      echo "wrote $out"
      SH
      chmod 0755 /usr/local/bin/write-report

      cat > /etc/systemd/system/report-writer.service <<'UNIT'
      [Unit]
      Description=Report writer
      After=local-fs.target

      [Service]
      Type=oneshot
      User=svc-report
      Group=svc-report
      UMask=0077
      ExecStart=/usr/local/bin/write-report

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable report-writer.service >/dev/null 2>&1 || true

      # Two reports from before the directory was rebuilt, with the ownership
      # and mode the pipeline expects. They are the specification: whatever the
      # service produces next has to look like these.
      for stamp in 20260801T0300 20260802T0300; do
        f=/srv/reports/report-$stamp.csv
        printf 'generated_at,rows\n%s,412\n' "$stamp" > "$f"
        chown svc-report:reports "$f"
        chmod 0640 "$f"
      done

      systemctl start report-writer.service >/dev/null 2>&1 || true

      echo "scenario ready — report-writer.service failed its last run"
      systemctl --no-pager --lines=0 status report-writer.service 2>&1 | head -5 || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      dir=/srv/reports

      if [ ! -d "$dir" ]; then
        echo "not yet: $dir does not exist — reset the lesson to get it back"
        exit 1
      fi

      # Nothing about the old files is evidence. The question is what the
      # service produces from here, so the check makes it produce one.
      before=$(find "$dir" -maxdepth 1 -name 'report-*.csv' | wc -l)

      if ! systemctl start report-writer.service >/dev/null 2>&1; then
        echo "not yet: report-writer.service still fails when it runs"
        systemctl --no-pager --lines=5 status report-writer.service 2>&1 | tail -6
        exit 1
      fi

      after=$(find "$dir" -maxdepth 1 -name 'report-*.csv' | wc -l)
      if [ "$after" -le "$before" ]; then
        echo "not yet: the unit reported success and produced no new file in $dir"
        exit 1
      fi

      newest=$(find "$dir" -maxdepth 1 -name 'report-*.csv' -printf '%T@ %p\n' \
        | sort -rn | head -1 | cut -d' ' -f2-)

      owner=$(stat -c %U "$newest")
      if [ "$owner" != "svc-report" ]; then
        echo "not yet: the new report is owned by '$owner', not svc-report"
        echo "         running the unit as root makes the write succeed and defeats the point —"
        echo "         the service is meant to have exactly the access its own user has."
        exit 1
      fi

      grp=$(stat -c %G "$newest")
      if [ "$grp" != "reports" ]; then
        echo "not yet: the new report landed with group '$grp', not reports"
        echo "         $(basename "$newest")"
        echo "         chgrp on the files that already existed does not change what the"
        echo "         next file inherits. The group a new file gets is decided by the"
        echo "         directory it is created in."
        exit 1
      fi

      mode=$(stat -c %a "$newest")
      # Pad to four digits so the group triad is always at the same offset.
      padded=$(printf '%04d' "$mode")
      group_digit=${padded:2:1}
      if [ $(( group_digit & 4 )) -eq 0 ]; then
        echo "not yet: the new report is mode $mode — group cannot read it"
        echo "         the group is right, so the directory is right; this is the mask"
        echo "         the service applies to every file it creates."
        exit 1
      fi

      if ! su -s /bin/sh publisher -c "cat '$newest' >/dev/null 2>&1"; then
        echo "not yet: publisher still cannot read $(basename "$newest")"
        exit 1
      fi

      # 0777 on the directory, or 0666 on the files, makes every check above
      # pass. It is the fix everyone reaches for and it is not a fix: it grants
      # every account on the box write access to the reports.
      loose=$(find "$dir" -perm -0002 2>/dev/null | head -5)
      if [ -n "$loose" ]; then
        echo "not yet: these are world-writable, which is not the same as fixing the group:"
        echo "$loose" | sed 's/^/         /'
        echo "         any account on this box can rewrite a report. Give the group the"
        echo "         access it needs and nobody else."
        exit 1
      fi

      echo "PASS — report-writer wrote $(basename "$newest") as $owner:$grp mode $mode,"
      echo "       publisher can read it, and nothing under $dir is world-writable."
---
