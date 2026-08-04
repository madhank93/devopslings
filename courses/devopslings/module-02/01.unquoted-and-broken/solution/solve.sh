#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/archive-inbox <<'SH'
#!/bin/bash
set -euo pipefail

# Three separate fixes, and all of them are required:
#
#   * A glob, not `$(ls)`. Command substitution hands the shell a string, which
#     it then splits on whitespace and expands as globs — so "quarterly
#     report.csv" becomes two words, and a file literally named "*.csv" expands
#     to every csv in the directory. A glob yields real filenames, one array
#     element each, with no re-splitting.
#
#   * Quote every expansion. "$f" is one argument no matter what is in it.
#
#   * `--` before the operands, so a file named "-rf.txt" is treated as a path
#     and not as options to mv.
shopt -s nullglob
for f in /srv/inbox/*; do
  [ -f "$f" ] || continue
  mv -- "$f" /srv/archive/
done
SH
chmod 0755 /usr/local/bin/archive-inbox
