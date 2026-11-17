---
kind: lesson
title: "the $2,000 nobody spent"
description: |
  The October bill is $2,000 higher than September's and nobody deployed
  anything. The biggest instance on the account is the obvious suspect, and
  it is not the cause. Find the three things that are, from the billing
  export and the inventory, and say what fixing each one saves.
name: cost-surprise
slug: cost-surprise
createdAt: "2026-11-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 60
    run: |
      S=/var/lib/devopslings
      rm -rf /root/billing
      install -d /root/billing $S
      cat > $S/cost-surprise.gen <<'GEN'
      import csv, json, random, secrets, sys

      out, state = sys.argv[1], sys.argv[2]
      rid = lambda p: f"{p}-0{secrets.token_hex(8)}"
      inst = lambda: rid("i")
      vol = lambda: rid("vol")

      instances, volumes, rows = [], [], []


      def line(month, res, product, usage, amount, cost, owner):
          rows.append({"bill_month": month, "line_item_resource_id": res, "product_code": product,
                       "usage_type": usage, "usage_amount": f"{amount:.2f}", "unblended_cost": f"{cost:.2f}",
                       "resource_tags_user_owner": owner})


      def instance(itype, rate, az, owner, launched="2026-03-02", hours=(720, 744)):
          i = inst()
          tags = [{"Key": "owner", "Value": owner}] if owner else []
          root = vol()
          instances.append({"InstanceId": i, "InstanceType": itype, "Placement": {"AvailabilityZone": az},
                            "LaunchTime": f"{launched}T09:14:00Z", "State": {"Name": "running"}, "Tags": tags,
                            "BlockDeviceMappings": [{"DeviceName": "/dev/xvda", "Ebs": {"VolumeId": root}}]})
          volumes.append({"VolumeId": root, "Size": 100, "VolumeType": "gp3", "AvailabilityZone": az,
                          "State": "in-use", "Attachments": [{"InstanceId": i, "State": "attached"}], "Tags": tags,
                          "CreateTime": f"{launched}T09:14:00Z"})
          for m, h in zip(("2026-09", "2026-10"), hours):
              if h:
                  line(m, i, "AmazonEC2", f"BoxUsage:{itype}", h, h * rate, owner)
                  line(m, root, "AmazonEC2", "EBS:VolumeUsage.gp3", 100 * h / 720, 8.0 * h / 720, owner)
          return i


      big = instance("m5.8xlarge", 1.536, "us-east-1a", "analytics")
      app = instance("c6i.2xlarge", 0.34, "us-east-1a", "checkout")
      dbi = instance("r6i.2xlarge", 0.504, "us-east-1b", "checkout")
      for t, r, az, o in (("t3.large", 0.0832, "us-east-1a", "web"), ("t3.large", 0.0832, "us-east-1b", "web"),
                          ("m6i.xlarge", 0.192, "us-east-1a", "platform")):
          instance(t, r, az, o)
      untagged = instance("r5.4xlarge", 1.008, "us-east-1b", "", launched="2026-10-09", hours=(0, 23 * 24))

      # A new, attached volume: it is new spend, and it is in use.
      data_vol = vol()
      volumes.append({"VolumeId": data_vol, "Size": 500, "VolumeType": "gp3", "AvailabilityZone": "us-east-1a",
                      "State": "in-use", "Attachments": [{"InstanceId": app, "State": "attached"}],
                      "Tags": [{"Key": "owner", "Value": "checkout"}], "CreateTime": "2026-10-01T11:02:00Z"})
      line("2026-10", data_vol, "AmazonEC2", "EBS:VolumeUsage.gp3", 500, 40.00, "checkout")

      # Left behind by the database migration: io2 with provisioned IOPS, attached to nothing.
      orphans = {}
      for size, iops in ((1000, 3000), (1000, 2500), (750, 2500)):
          v = vol()
          volumes.append({"VolumeId": v, "Size": size, "VolumeType": "io2", "Iops": iops, "AvailabilityZone": "us-east-1b",
                          "State": "available", "Attachments": [], "Tags": [{"Key": "owner", "Value": "data-platform"}],
                          "CreateTime": "2026-09-30T22:40:00Z"})
          c = size * 0.125 + iops * 0.065
          line("2026-10", v, "AmazonEC2", "EBS:VolumeUsage.piops", size, size * 0.125, "data-platform")
          line("2026-10", v, "AmazonEC2", "EBS:VolumeP-IOPS.io2", iops, iops * 0.065, "data-platform")
          orphans[v] = round(c, 2)

      # Inter-AZ traffic between the app (1a) and its database (1b), billed on both sides.
      for i, owner in ((app, "checkout"), (dbi, "checkout")):
          line("2026-09", i, "AWSDataTransfer", "USE1-DataTransfer-Regional-Bytes", 2060, 20.60, owner)
          line("2026-10", i, "AWSDataTransfer", "USE1-DataTransfer-Regional-Bytes", 32640, 326.40, owner)
      for m, gb in (("2026-09", 1810), ("2026-10", 1846)):
          line(m, big, "AWSDataTransfer", "USE1-DataTransfer-Out-Bytes", gb, gb * 0.09, "analytics")
      for m, c in (("2026-09", 61.30), ("2026-10", 73.85)):
          line(m, "", "AmazonEC2", "EBS:SnapshotUsage", c / 0.05, c, "")

      random.shuffle(rows)
      for m in ("2026-09", "2026-10"):
          with open(f"{out}/cur-{m}.csv", "w", newline="") as f:
              w = csv.DictWriter(f, fieldnames=list(rows[0]))
              w.writeheader()
              w.writerows(r for r in rows if r["bill_month"] == m)
      random.shuffle(instances); random.shuffle(volumes)
      json.dump({"Reservations": [{"Instances": instances}]}, open(f"{out}/describe-instances.json", "w"), indent=2)
      json.dump({"Volumes": volumes}, open(f"{out}/describe-volumes.json", "w"), indent=2)
      untagged_root = next(v["VolumeId"] for v in volumes if v["Attachments"] and v["Attachments"][0]["InstanceId"] == untagged)
      untagged_cost = sum(float(r["unblended_cost"]) for r in rows
                          if r["bill_month"] == "2026-10" and r["line_item_resource_id"] in (untagged, untagged_root))
      json.dump({"orphans": orphans, "orphan_saving": round(sum(orphans.values()), 2),
                 "xaz": [app, dbi], "xaz_saving": 652.80,
                 "xaz_all": round(sum(float(r["unblended_cost"]) for r in rows
                                      if r["bill_month"] == "2026-10" and r["line_item_resource_id"] in (app, dbi)), 2),
                 "untagged": untagged, "untagged_root": untagged_root, "untagged_saving": round(untagged_cost, 2),
                 "big": big, "data_vol": data_vol},
                open(state, "w"), indent=2)
      GEN
      python3 $S/cost-surprise.gen /root/billing $S/cost-surprise.json
      cd /root/billing
      cat > FINDINGS <<'TXT'
      # One line per contributor to the increase. Replace each ? .
      #
      #   <kind>: <resource ids, space-separated> saving=<USD per month>
      #
      # saving is what fixing it takes off a month like October.
      unattached-volumes: ? saving=?
      cross-zone-egress: ? saving=?
      untagged: ? saving=?
      TXT
      cat > README <<'TXT'
      The October bill is about $2,000 higher than September's. Nobody
      deployed anything new on purpose.

        cur-2026-09.csv, cur-2026-10.csv    the cost and usage export, one
                                            line per resource and usage type
        describe-instances.json             this morning's inventory, as
        describe-volumes.json               `aws ec2 describe-*` returns it

      Three things account for most of the increase:

        - EBS volumes that are attached to nothing
        - traffic between availability zones
        - a resource nobody owns: it has no owner tag

      Find each one, and write in FINDINGS the resource IDs it involves and
      what fixing it saves per month, from October's figures. Fixing means
      deleting the volumes, keeping the traffic inside one zone, and
      stopping the resource.

      jq, python3 and awk are installed. Nothing needs to be deleted: you
      are graded on FINDINGS.
      TXT
      echo "scenario ready — /root/billing: read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      S=/var/lib/devopslings
      if [ ! -s $S/cost-surprise.json ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      if [ ! -s /root/billing/FINDINGS ]; then
        echo "not yet: /root/billing/FINDINGS is missing — reset the lesson to get the template back"
        exit 1
      fi
      python3 - $S/cost-surprise.json /root/billing/FINDINGS <<'PY' || exit 1
      import json, re, sys
      want = json.load(open(sys.argv[1]))
      lines = {}
      for raw in open(sys.argv[2]):
          m = re.match(r"\s*(unattached-volumes|cross-zone-egress|untagged)\s*:(.*)", raw)
          if m:
              lines.setdefault(m.group(1), m.group(2))

      def fail(*ls):
          print("not yet: " + ls[0])
          for l in ls[1:]:
              print("         " + l)
          sys.exit(1)

      def parse(kind):
          if kind not in lines:
              fail(f"FINDINGS has no '{kind}:' line")
          body = lines[kind]
          ids = set(re.findall(r"\b(?:i|vol)-[0-9a-f]+\b", body))
          m = re.search(r"saving\s*=\s*\$?([0-9][0-9,]*(?:\.[0-9]+)?)", body)
          if not ids:
              fail(f"the {kind} line names no resource IDs")
          if not m:
              fail(f"the {kind} line has no saving=<USD per month>")
          return ids, float(m.group(1).replace(",", ""))

      def saving(kind, got, exp, what, lines="lines"):
          if abs(got - exp) <= exp * 0.10:
              return
          hint = ""
          if kind == "cross-zone-egress" and abs(got - want["xaz_all"]) <= want["xaz_all"] * 0.10:
              hint = "That is everything the two instances cost. Moving zones removes only the transfer."
          elif kind == "untagged" and exp < got < exp * 1.6:
              hint = "It did not run all of October: look at its LaunchTime."
          elif abs(got - exp * 12) <= exp * 1.2:
              hint = "That is about a year of it; the question is per month."
          elif got > exp * 1.5:
              hint = "That is more than October's lines for it add up to."
          fail(f"{kind}: the resources are right, and saving={got:g} is not what {what} saves per month.",
               *([hint] if hint else []), f"Add up October's unblended_cost {lines} for those resource IDs")

      big = want["big"]
      for kind in lines:
          if big in lines[kind]:
              fail(f"FINDINGS names {big}, the m5.8xlarge, under {kind}. It is the biggest line",
                   "on the bill, and it cost the same in September: it is not part of the increase.",
                   "Compare each resource's cost across the two months")

      ids, s = parse("unattached-volumes")
      orph = set(want["orphans"])
      extra, missing = ids - orph, orph - ids
      if extra:
          x = sorted(extra)[0]
          why = "is attached to an instance (State in-use)" if x.startswith("vol-") else "is not a volume"
          if x == want["data_vol"]:
              why = "is new in October, and it is attached and in use: new spend, not waste"
          fail(f"unattached-volumes names {x}, which {why}.",
               "Unattached means State available, with no Attachments")
      if missing:
          fail(f"unattached-volumes lists {len(ids)} volume(s); {len(orph)} are attached to nothing.",
               "describe-volumes.json has every volume with State available")
      saving("unattached-volumes", s, want["orphan_saving"], "deleting them")

      ids, s = parse("cross-zone-egress")
      xaz = set(want["xaz"])
      if not ids <= xaz:
          x = sorted(ids - xaz)[0]
          fail(f"cross-zone-egress names {x}. Traffic between zones is billed as",
               "usage type USE1-DataTransfer-Regional-Bytes; DataTransfer-Out is traffic to the",
               "internet, which a zone move does not change")
      if ids != xaz:
          fail("cross-zone-egress names one end of the traffic. Inter-zone transfer is billed on",
               "both sides, and both resources' lines go away when they share a zone")
      saving("cross-zone-egress", s, want["xaz_saving"], "keeping that traffic in one zone",
             "DataTransfer-Regional-Bytes lines")

      ids, s = parse("untagged")
      if want["untagged"] not in ids:
          fail("untagged does not name the resource with no owner tag. Look for an instance in",
               "describe-instances.json with no owner in its Tags, and in October's export for",
               "lines with an empty resource_tags_user_owner")
      if ids - {want["untagged"], want["untagged_root"]}:
          x = sorted(ids - {want["untagged"], want["untagged_root"]})[0]
          fail(f"untagged also names {x}, which has an owner tag")
      exp = want["untagged_saving"]
      # Its root volume is a few dollars; counting it or not are both right.
      if not (exp * 0.85 <= s <= exp * 1.1):
          saving("untagged", s, exp, "stopping it")
      PY
      echo "PASS — the three contributors are named, with what fixing each saves per month."
---
