---
title: "the archive script that ate the quarterly report"
---

## The situation

`archive-inbox` has run every night for a year. Yesterday somebody saved a file
called `quarterly report.csv`, and this morning the archive contains a file
named `quarterly` and a file named `report.csv`, neither of which is the
report.

```
$ cat /usr/local/bin/archive-inbox
for f in $(ls /srv/inbox); do
  mv /srv/inbox/$f /srv/archive/
done
```

There are five files in `/srv/inbox` and four of them are a problem:

```
$ ls -1b /srv/inbox
*.csv
-rf.txt
orders.csv
quarterly report.csv
two\nlines.txt
```

## Your objective

Fix `/usr/local/bin/archive-inbox` so every file arrives in `/srv/archive` with
its name and contents intact — whatever the name contains.

## What you're being graded on

The check rebuilds the inbox from scratch, runs **your** script, and compares
the archive against the original names and contents by checksum. All five, byte
for byte, with an empty inbox at the end.

<details>
<summary>Hint 1 — what `$(ls)` actually hands you</summary>

Command substitution does not produce a list of filenames. It produces **one
string**, and then the shell does two more things to it before your loop ever
sees it:

1. **Word splitting** on `$IFS` — space, tab, newline. `quarterly report.csv`
   becomes two words.
2. **Pathname expansion** — any word containing `*`, `?` or `[` is expanded as a
   glob. The file literally named `*.csv` becomes every `.csv` in the directory.

So a five-file directory can yield eight words, some of which name files that
were never there and some of which name the same file twice.

Watch it happen:

```
$ for f in $(ls /srv/inbox); do echo "[$f]"; done
```

Every `[...]` should be one real filename. Count how many are not.

</details>

<details>
<summary>Hint 2 — use a glob, and quote it</summary>

A glob is expanded by the shell into real pathnames, one per match, and the
results are **not** re-split or re-expanded. That is the whole difference.

```bash
for f in /srv/inbox/*; do
  echo "[$f]"
done
```

Two things still needed:

- **Quote the expansion.** `mv $f` re-splits the value; `mv "$f"` passes one
  argument. Quoting is not decoration — it is what stops step 1 happening
  again.
- **`shopt -s nullglob`.** An unmatched glob expands to *itself*, so an empty
  directory hands you the literal string `/srv/inbox/*`. `nullglob` makes it
  expand to nothing instead, and the loop body simply does not run.

</details>

<details>
<summary>Hint 3 — the file named `-rf.txt`</summary>

```
$ mv "/srv/inbox/-rf.txt" /srv/archive/
```

That one is fine, because the path starts with `/`. But this is not:

```
$ cd /srv/inbox && mv -rf.txt /srv/archive/
mv: invalid option -- 'r'
```

Anything beginning with `-` is read as options. Two standard defences:

```bash
mv -- "$f" /srv/archive/      # -- ends option parsing
mv "./$f" /srv/archive/       # ./ makes it unambiguously a path
```

Use `--` on every command that takes filenames from a variable. This is the same
class of bug as a filename containing `;` or `$(...)` reaching `eval` — data
being read as syntax.

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
set -euo pipefail

shopt -s nullglob
for f in /srv/inbox/*; do
  [ -f "$f" ] || continue
  mv -- "$f" /srv/archive/
done
```

For the general case — recursion, or a list produced by another program — the
same rules apply with a NUL-delimited stream, because NUL is the only byte a
filename cannot contain:

```bash
find /srv/inbox -maxdepth 1 -type f -print0 \
  | while IFS= read -r -d '' f; do
      mv -- "$f" /srv/archive/
    done
```

`IFS=` stops leading and trailing whitespace being trimmed, `-r` stops
backslashes being interpreted, and `-d ''` reads up to a NUL. All three are
needed; each one drops a different set of filenames.

### Why this is a lesson at all

The script was correct for a year, and it was never correct — it was *lucky*,
because every filename anyone had used happened to contain no character the
shell treats as syntax. That is not a property of the script; it is a property
of the inputs it had seen.

Three rules that between them close nearly all of it:

1. **Never iterate over `$(ls)`.** Use a glob. `ls` formats output for humans,
   and the shell then re-parses that formatting as syntax. Two lossy
   conversions for something the shell can give you directly.
2. **Quote every expansion.** `"$f"`, `"$@"`, `"${arr[@]}"`. The exceptions are
   rare enough that the habit should be unconditional.
3. **`--` before filename operands.** Data starting with `-` is otherwise read
   as options.

And the failure mode is worth noting for its own sake: this script did not
crash. It moved files successfully, exited 0, and destroyed a filename. Silent
corruption is the expensive kind, because nothing points at the cause and the
damage is discovered later by someone else looking for a report.

</details>
