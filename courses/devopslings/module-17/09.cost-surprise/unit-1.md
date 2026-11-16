---
title: "the $2,000 nobody spent"
---

## The situation

The October bill is about $2,000 higher than September's, and nobody
deployed anything on purpose. The first suspect is the m5.8xlarge: it is the
biggest line on the bill. It also cost the same in September. A bill that
went *up* is explained by what *changed*, and the biggest line is usually
the one that did not.

`/root/billing` has two months of the cost and usage export (one line per
resource and usage type) and this morning's inventory, as
`aws ec2 describe-instances` and `describe-volumes` return it. Three things
account for most of the increase:

- EBS volumes that are attached to nothing
- traffic between availability zones
- a resource nobody owns: it has no `owner` tag

## Your objectives

For each of the three, write in `/root/billing/FINDINGS` the resource IDs it
involves and what fixing it saves per month, from October's figures. Fixing
means deleting the volumes, keeping the traffic inside one zone, and
stopping the resource.

## What you're being graded on

Each line must name exactly the resources involved: every unattached volume
and no attached one, both ends of the inter-zone traffic, and the resource
with no owner. Each saving must be within 10% of the October lines the fix
removes: for the inter-zone traffic, that is the transfer, not the instances.
Naming the m5.8xlarge anywhere fails.

<details>
<summary>Hint 1 — what changed</summary>

Sum `unblended_cost` per resource in each month and compare. In awk:

```
awk -F, 'NR>1 {s[$2" "$4] += $6} END {for (k in s) printf "%10.2f %s\n", s[k], k}' \
  cur-2026-10.csv | sort -rn | head -20
```

Do the same for September and look for what is new or grew.

</details>

<details>
<summary>Hint 2 — unattached</summary>

```
jq -r '.Volumes[] | select(.State == "available") | .VolumeId' describe-volumes.json
```

A volume left behind by a migration still bills for its size, and io2
volumes bill for their provisioned IOPS too, whether anything reads them or
not.

</details>

<details>
<summary>Hint 3 — inter-zone traffic</summary>

Traffic between zones in one region is usage type
`USE1-DataTransfer-Regional-Bytes`, charged per GB on both sides of the
connection. `DataTransfer-Out` is traffic to the internet, which moving zones
does not change.

</details>

<details>
<summary>Solution</summary>

```
oct() { awk -F, -v ids=" $* " 'NR > 1 && index(ids, " " $2 " ") {s += $6}
        END {printf "%.2f", s}' cur-2026-10.csv; }
vols=$(jq -r '.Volumes[] | select(.State == "available") | .VolumeId' describe-volumes.json | xargs)
xaz=$(awk -F, '$4 ~ /DataTransfer-Regional/ && $2 != "" {print $2}' cur-2026-10.csv | sort -u | xargs)
untagged=$(jq -r '.Reservations[].Instances[]
  | select((.Tags // []) | map(.Key) | index("owner") | not) | .InstanceId' describe-instances.json | xargs)
cat > FINDINGS <<TXT
unattached-volumes: $vols saving=$(oct $vols)
cross-zone-egress: $xaz saving=$(grep Regional cur-2026-10.csv | awk -F, '{s += $6} END {printf "%.2f", s}')
untagged: $untagged saving=$(oct $untagged)
TXT
```

### Keeping it from happening again

Each of the three has a standing control. A scheduled check for volumes in
state `available` older than a week. An application and its database in the
same zone, or a deliberate decision that the cross-zone cost buys
availability. And a tag policy, or a service control policy, that refuses to
launch anything without an `owner` tag, so the next resource nobody owns
cannot exist.

</details>
