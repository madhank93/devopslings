---
kind: lesson
title: "the security update that apt quietly declined to install"
description: |
  The patch went out three weeks ago. `apt upgrade` has run nightly and exited
  0 every time. ledger-tools is still on the vulnerable version, and apt has
  been telling you so in a line nobody reads. Four things make apt hold a
  package back and they are fixed four different ways.
name: package-held-back
slug: package-held-back
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /root/answers /var/lib/devopslings
      arch=$(dpkg --print-architecture)
      repo=/srv/localrepo
      rm -rf "$repo" /tmp/ltbuild
      mkdir -p "$repo" /tmp/ltbuild

      # A tiny local archive standing in for the distribution's. Everything is
      # offline; the mechanics of hold, candidate and upgrade are identical.
      build() {
        v=$1 desc=$2 d=/tmp/ltbuild/lt-$1
        mkdir -p "$d/DEBIAN" "$d/usr/bin"
        cat > "$d/DEBIAN/control" <<CTL
      Package: ledger-tools
      Version: $v
      Architecture: $arch
      Maintainer: platform <platform@example.internal>
      Section: utils
      Priority: optional
      Description: Ledger export helper
       $desc
      CTL
        printf '#!/bin/sh\necho "ledger-tools %s"\n' "$v" > "$d/usr/bin/ledger-tools"
        chmod 0755 "$d/usr/bin/ledger-tools"
        dpkg-deb --build -Znone "$d" "$repo/ledger-tools_${v}_${arch}.deb" >/dev/null
      }
      build 1.0 "Initial release."
      build 1.1 "Fixes CVE-2026-3312: unauthenticated export endpoint."

      # No dpkg-scanpackages or apt-ftparchive in this image, so the index is
      # written by hand. apt only needs the stanza, the path and the digest.
      cd "$repo"
      : > Packages
      for f in *.deb; do
        {
          dpkg-deb -f "$f" | sed '/^$/d'
          echo "Filename: $f"
          echo "Size: $(stat -c %s "$f")"
          echo "SHA256: $(sha256sum "$f" | cut -d' ' -f1)"
          echo
        } >> Packages
      done
      gzip -kf Packages

      echo "deb [trusted=yes] file:/srv/localrepo ./" > /etc/apt/sources.list.d/local.list
      apt-get update -qq >/dev/null 2>&1 || true

      apt-get install -y -qq --allow-downgrades ledger-tools=1.0 >/dev/null 2>&1

      # The hold. Somebody pinned it during an incident in June to stop a
      # rollout, wrote it in a ticket, and closed the ticket.
      apt-mark hold ledger-tools >/dev/null 2>&1

      echo hold > /var/lib/devopslings/package-held-back.reason
      echo 1.1  > /var/lib/devopslings/package-held-back.version

      cat > /root/questions.txt <<'Q'
      ledger-tools is on 1.0. 1.1 fixes CVE-2026-3312 and the fleet was supposed
      to have it three weeks ago.

        /root/answers/reason   why apt is not installing it. One of:
                                 hold      someone marked the package held
                                 phasing   a phased/staged rollout
                                 newdeps   the upgrade needs new packages
                                 pin       apt preferences prefer another version

        Then actually get ledger-tools onto 1.1, and leave no held packages
        behind.
      Q

      echo "scenario ready — ledger-tools $(dpkg-query -W -f='${Version}' ledger-tools) installed; 1.1 is available and apt will not take it"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      want_reason=$(cat /var/lib/devopslings/package-held-back.reason)
      want_version=$(cat /var/lib/devopslings/package-held-back.version)

      if [ ! -s /root/answers/reason ]; then
        echo "not yet: /root/answers/reason is missing or empty"
        echo "         one of: hold, phasing, newdeps, pin"
        exit 1
      fi

      got=$(tr -d '[:space:]' < /root/answers/reason | tr 'A-Z' 'a-z')
      if [ "$got" != "$want_reason" ]; then
        case "$got" in
          phasing)
            echo "not yet: a phased rollout shows up as 'deferred due to phasing' and"
            echo "         resolves itself over a few days. This has been stuck for three"
            echo "         weeks and says 'kept back' instead."
            ;;
          newdeps)
            echo "not yet: that is the 'apt upgrade will not install new packages' case,"
            echo "         and 'apt full-upgrade' would clear it. Try it — it changes"
            echo "         nothing here."
            ;;
          pin)
            echo "not yet: a pin changes which version apt *wants*. Look at"
            echo "         'apt-cache policy ledger-tools' — the candidate is already 1.1,"
            echo "         so apt wants the new one and is still not installing it."
            ;;
          *)
            echo "not yet: '$got' is not one of hold, phasing, newdeps, pin"
            ;;
        esac
        exit 1
      fi

      installed=$(dpkg-query -W -f='${Version}' ledger-tools 2>/dev/null || echo none)
      if [ "$installed" != "$want_version" ]; then
        echo "not yet: ledger-tools is at version '$installed', not $want_version"
        echo "         you have named the mechanism; now undo it and upgrade."
        exit 1
      fi

      # The package database can say one thing while the filesystem says
      # another. Ask the binary.
      reported=$(ledger-tools 2>/dev/null || echo "")
      case "$reported" in
        *"$want_version"*) ;;
        *)
          echo "not yet: dpkg says $want_version but 'ledger-tools' reports: ${reported:-nothing}"
          exit 1
          ;;
      esac

      held=$(apt-mark showhold 2>/dev/null)
      if [ -n "$held" ]; then
        echo "not yet: these packages are still held, so the next upgrade will skip them too:"
        printf '%s\n' "$held" | sed 's/^/         /'
        exit 1
      fi

      echo "PASS — ledger-tools $installed installed, nothing held, and the binary agrees."
---
