---
title: "the delete that was not a delete"
---

## The situation

The `ledgers` bucket has versioning on. Two things went wrong last night.

The settlement job failed halfway. It overwrote `settlement/ledger.csv` with a
file holding only its header, then its cleanup step deleted it. Finance needs
the last complete ledger back. A complete ledger ends with a `TOTAL` line.

Every night the export job writes a file to `exports/`, ships it, and deletes
it. `aws s3 ls` shows an empty prefix, and the storage bill grows every day.

Both have the same cause. On a versioned bucket, an overwrite keeps the old
object as a **noncurrent version**. A delete removes nothing: it puts a
**delete marker** on top, and the object underneath becomes noncurrent.
Noncurrent versions are stored, and billed, until something removes them.

Finance's rule: anything overwritten or deleted in this bucket can be
recovered for 30 days. After that it is not needed.

## Your objectives

1. `settlement/ledger.csv` is the last complete ledger.
2. A lifecycle rule on the whole bucket removes old versions once the 30-day
   window has passed, and never touches the current version of anything.
3. Everything inside the recovery window now stays recoverable: do not
   delete old versions by hand.
4. Answer the question in `/root/ledgers/ANSWER`.

## What you're being graded on

Versioning must still be on. `settlement/ledger.csv` must be byte-for-byte
the newest complete ledger the bucket held. Every old version under
`exports/` must still exist. The lifecycle configuration must have an enabled
rule for the whole bucket with a `NoncurrentVersionExpiration` of 30 to 60
days, and no enabled rule may expire current versions.

floci stores lifecycle rules and does not run them. The grader reads the
rule, as AWS would apply it.

<details>
<summary>Hint 1 — seeing the versions</summary>

```
aws s3api list-object-versions --bucket ledgers --prefix settlement/
```

Each version has a `VersionId`, a `LastModified` and a size. The delete
marker is listed separately. `aws s3api get-object --version-id ...` reads one
version.

</details>

<details>
<summary>Hint 2 — getting it back</summary>

Removing the delete marker (`delete-object --version-id <marker id>`) makes
the version under it current again, and that one is the header-only file.
Either remove that too, or copy the version you want on top:
`copy-object --copy-source "ledgers/settlement/ledger.csv?versionId=..."`.

</details>

<details>
<summary>Hint 3 — which expiration</summary>

`Expiration` acts on current versions: `Days: 30` deletes every live object
once it is 30 days old. `NoncurrentVersionExpiration` with `NoncurrentDays`
counts from when a version stopped being current, which is the recovery
window.

</details>

<details>
<summary>Solution</summary>

```
v=$(aws s3api list-object-versions --bucket ledgers --prefix settlement/ledger.csv \
  --query 'Versions[1].VersionId' --output text)     # check it ends with TOTAL first
aws s3api copy-object --bucket ledgers --key settlement/ledger.csv \
  --copy-source "ledgers/settlement/ledger.csv?versionId=$v"
aws s3api put-bucket-lifecycle-configuration --bucket ledgers --lifecycle-configuration '{
  "Rules": [{"ID": "old-versions", "Status": "Enabled", "Filter": {},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
    "Expiration": {"ExpiredObjectDeleteMarker": true}}]}'
```

```
rm_kept=kept-as-noncurrent
```

`ExpiredObjectDeleteMarker` removes a delete marker once nothing is left
under it, so `exports/` does not fill with markers either.

### Why not turn versioning off

Suspending versioning stops new versions, keeps every old one, and removes
the only thing that brought the ledger back. The lifecycle rule keeps the
safety and puts a ceiling on what it costs: at most 30 days of overwrites
and deletes.

</details>
