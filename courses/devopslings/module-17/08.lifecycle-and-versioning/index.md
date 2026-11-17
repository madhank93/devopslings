---
kind: lesson
title: "the delete that was not a delete"
description: |
  A failed job overwrote the settlement ledger and then deleted it, and the
  bucket bill keeps growing although the cleanup job deletes every export.
  Both are versioning. Get the ledger back, and write the lifecycle rule
  that stops paying for old versions without giving up the recovery window.
name: lifecycle-and-versioning
slug: lifecycle-and-versioning
createdAt: "2026-11-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      S=/var/lib/devopslings
      B=ledgers
      if aws s3api head-bucket --bucket $B >/dev/null 2>&1; then
        aws s3api list-object-versions --bucket $B --output json \
          | jq -r '(.Versions // []) + (.DeleteMarkers // []) | .[] | [.Key, .VersionId] | @tsv' \
          | while IFS=$'\t' read -r k id; do aws s3api delete-object --bucket $B --key "$k" --version-id "$id" >/dev/null; done
        aws s3api delete-bucket-lifecycle --bucket $B 2>/dev/null || true
        aws s3api delete-bucket --bucket $B
      fi
      rm -rf /root/ledgers
      install -d /root/ledgers $S
      aws s3 mb s3://$B >/dev/null
      aws s3api put-bucket-versioning --bucket $B --versioning-configuration Status=Enabled

      ledger() {
        for i in $(seq 1 "$1"); do printf 'acct-%04d,%d.%02d\n' $((RANDOM % 9000 + 1000)) $((RANDOM % 5000)) $((RANDOM % 100)); done > /tmp/rows
        echo "account,amount"
        cat /tmp/rows
        awk -F, '{s += $2} END {printf "TOTAL,%.2f\n", s}' /tmp/rows
        rm -f /tmp/rows
      }
      put() { aws s3 cp "$1" "s3://$B/settlement/ledger.csv" >/dev/null; sha256sum "$1" | cut -d' ' -f1; }
      ledger 180 > /tmp/l1; ledger 214 > /tmp/l2; echo "account,amount" > /tmp/l3
      put /tmp/l1 > $S/ledger.v1; sleep 1
      put /tmp/l2 > $S/ledger.v2; sleep 1
      put /tmp/l3 > $S/ledger.v3
      rm -f /tmp/l1 /tmp/l2 /tmp/l3
      aws s3 rm s3://$B/settlement/ledger.csv >/dev/null

      # The nightly export job writes a file, ships it, and deletes it.
      for d in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
        head -c 20000 /dev/urandom | base64 > /tmp/export.json
        aws s3 cp /tmp/export.json s3://$B/exports/2026-11-$d.json >/dev/null
        aws s3 rm s3://$B/exports/2026-11-$d.json >/dev/null
      done
      rm -f /tmp/export.json
      aws s3api list-object-versions --bucket $B --prefix exports/ --query 'length(Versions)' --output text > $S/ledger.exports

      cd /root/ledgers
      cat > ANSWER <<'TXT'
      # Replace the ? with one of the listed words.
      #
      # On this versioned bucket, what did `aws s3 rm` do to the bytes of the
      # object it removed?          freed | kept-as-noncurrent | moved-to-glacier
      rm_kept=?
      TXT
      cat > README <<'TXT'
      The ledgers bucket has versioning on.

      1. Last night's settlement job failed halfway: it overwrote
         settlement/ledger.csv with a file holding only its header, then its
         cleanup step deleted it. Finance needs the last complete ledger
         back at settlement/ledger.csv. A complete ledger ends with a TOTAL
         line.

      2. The export job writes a file to exports/ every night, ships it, and
         deletes it. `aws s3 ls --recursive s3://ledgers/exports/` shows
         nothing, and the bucket's storage bill grows every day.

      The rule, from finance: anything overwritten or deleted in this bucket
      can be recovered for 30 days. After that it is not needed.

      Fix it:

        - settlement/ledger.csv is the last complete ledger.
        - A lifecycle rule on the whole bucket removes old versions once the
          30-day recovery window has passed, and never touches the current
          version of anything.
        - Everything that is inside the recovery window now stays recoverable.
        - Answer the question in ANSWER.
      TXT
      echo "scenario ready — /root/ledgers: read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      S=/var/lib/devopslings
      B=ledgers
      if [ ! -s $S/ledger.v2 ] || [ ! -s $S/ledger.exports ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      if ! aws s3api head-bucket --bucket $B >/dev/null 2>&1; then
        echo "not yet: the ledgers bucket is gone — reset the lesson to get it back"
        exit 1
      fi
      vs=$(aws s3api get-bucket-versioning --bucket $B --query Status --output text 2>/dev/null || true)
      if [ "$vs" != Enabled ]; then
        echo "not yet: versioning on the bucket is ${vs:-off}. Without it the next overwrite or"
        echo "         delete is final, and the 30-day recovery window is gone. Turn it back on"
        exit 1
      fi

      tmp=$(mktemp); trap 'rm -f $tmp' EXIT
      if ! aws s3 cp s3://$B/settlement/ledger.csv $tmp >/dev/null 2>&1; then
        echo "not yet: settlement/ledger.csv cannot be read: its latest version is still the"
        echo "         delete marker. The data is in the versions under it:"
        echo "         aws s3api list-object-versions --bucket $B --prefix settlement/"
        exit 1
      fi
      got=$(sha256sum $tmp | cut -d' ' -f1)
      if [ "$got" != "$(cat $S/ledger.v2)" ]; then
        if [ "$got" = "$(cat $S/ledger.v3)" ]; then
          echo "not yet: settlement/ledger.csv is back, and it is the header-only file the failed"
          echo "         job wrote, the newest version under the delete marker. The complete"
          echo "         ledger is older still"
        elif [ "$got" = "$(cat $S/ledger.v1)" ]; then
          echo "not yet: settlement/ledger.csv is complete, and it is the oldest ledger, not the"
          echo "         last complete one. There is a newer version with a TOTAL line"
        else
          echo "not yet: settlement/ledger.csv is not any version the bucket held. Restore one of"
          echo "         its versions rather than writing a new file"
        fi
        exit 1
      fi

      left=$(aws s3api list-object-versions --bucket $B --prefix exports/ --query 'length(Versions)' --output text 2>/dev/null || echo 0)
      [ "$left" = None ] && left=0
      if [ "$left" -lt "$(cat $S/ledger.exports)" ]; then
        echo "not yet: $(( $(cat $S/ledger.exports) - left )) old versions under exports/ were deleted by hand. All of them"
        echo "         were written in the last two weeks, inside the 30-day recovery window."
        echo "         The lifecycle rule removes them when the window has passed"
        exit 1
      fi

      lc=$(aws s3api get-bucket-lifecycle-configuration --bucket $B --output json 2>/dev/null || true)
      if [ -z "$lc" ]; then
        echo "not yet: the ledger is back, and the bucket has no lifecycle configuration, so"
        echo "         every old version is kept, and billed, for ever"
        exit 1
      fi
      python3 - "$lc" <<'PY' || exit 1
      import json, sys
      rules = [r for r in json.loads(sys.argv[1]).get("Rules", []) if r.get("Status") == "Enabled"]

      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      def prefix(r):
          f = r.get("Filter")
          if not f:
              return r.get("Prefix", "")
          if "Prefix" in f:
              return f["Prefix"]
          if "And" in f:
              return None if f["And"].get("Tags") else f["And"].get("Prefix", "")
          return None  # a tag or size filter: only some objects

      if not rules:
          fail("the lifecycle configuration has no enabled rule")
      for r in rules:
          e = r.get("Expiration") or {}
          if "Days" in e or "Date" in e:
              fail(f"rule {r.get('ID', '?')} has an Expiration of {e.get('Days', e.get('Date'))}"
                   f"{' days' if 'Days' in e else ''}. Expiration acts on current versions:",
                   "it deletes the live ledger and every live object once it is that old. Old",
                   "versions are NoncurrentVersionExpiration")
      nve = [(r, (r.get("NoncurrentVersionExpiration") or {}).get("NoncurrentDays")) for r in rules]
      nve = [(r, d) for r, d in nve if d is not None]
      if not nve:
          fail("no enabled rule has a NoncurrentVersionExpiration, so old versions are still kept",
               "for ever. That is the action that removes a version some time after it stops",
               "being current")
      for r, d in nve:
          if d < 30:
              p = prefix(r)
              scope = "anywhere in the bucket" if p == "" else (f"under prefix {p!r}" if p is not None else "matching its tag or size filter")
              fail(f"rule {r.get('ID', '?')} removes old versions {scope} {d} day{'' if d == 1 else 's'} after they stop",
                   f"being current. Something overwritten or deleted on day 1 is gone on day {d + 1},",
                   "inside finance's 30-day recovery window, which covers the whole bucket")
      whole = [(r, d) for r, d in nve if prefix(r) == ""]
      if not whole:
          r, _ = nve[0]
          p = prefix(r)
          fail(f"the rule that expires old versions applies only to {('prefix ' + repr(p)) if p is not None else 'objects matching its tag or size filter'}.",
               "The rule is for the whole bucket: an overwritten ledger piles up versions too")
      d = min(d for _, d in whole)
      if d > 60:
          fail(f"old versions are kept {d} days. The recovery window is 30, so most of what",
               "the bucket pays for is versions nobody needs")
      PY

      ans=$(sed -n 's/^[[:space:]]*rm_kept[[:space:]]*=[[:space:]]*\([A-Za-z?-]*\).*/\1/p' /root/ledgers/ANSWER 2>/dev/null | head -1)
      case "$ans" in
        kept-as-noncurrent) ;;
        freed) echo "not yet: ANSWER says rm freed the bytes. On a versioned bucket it adds a delete"
               echo "         marker on top; the object becomes a noncurrent version, still stored and"
               echo "         still billed. That is how the ledger came back"; exit 1 ;;
        moved-to-glacier) echo "not yet: ANSWER says rm moved the bytes to Glacier. Only a lifecycle transition"
                          echo "         does that, and this bucket had none. Look at what list-object-versions shows"; exit 1 ;;
        *) echo "not yet: ANSWER needs rm_kept= one of: freed kept-as-noncurrent moved-to-glacier"; exit 1 ;;
      esac
      echo "PASS — the last complete ledger is back, old versions expire 30 to 60 days after"
      echo "       they stop being current, and nothing current or inside the window is touched."
---
