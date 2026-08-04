#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/rotate-logs <<'SH'
#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: rotate-logs --dir <path> [--days <n>] [--compress]

  --dir <path>   directory of *.log files to rotate (required)
  --days <n>     archive files older than n days (default: 7)
  --compress     gzip each file after archiving (default: off)
  -h, --help     show this message
USAGE
}

# Defaults live here, in one place, rather than being implied by argument
# position.
dir=""
days=7
compress=no

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)      dir=${2:-};  shift 2 ;;
    --days)     days=${2:-}; shift 2 ;;
    --compress) compress=yes; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    # An unrecognised flag is an error, never a silent no-op. A typo that is
    # ignored runs the script with a default nobody chose.
    -*)         printf 'rotate-logs: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *)          printf 'rotate-logs: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Validate before doing anything destructive, and name what is missing.
if [ -z "$dir" ]; then
  printf 'rotate-logs: --dir is required\n\n' >&2
  usage >&2
  exit 2
fi
if [ ! -d "$dir" ]; then
  printf 'rotate-logs: --dir %s: not a directory\n' "$dir" >&2
  exit 2
fi
case "$days" in
  ''|*[!0-9]*) printf 'rotate-logs: --days must be a whole number, got: %s\n' "$days" >&2; exit 2 ;;
esac

mkdir -p "$dir/archive"
find "$dir" -maxdepth 1 -type f -name '*.log' -mtime +"$days" -print0 \
  | while IFS= read -r -d '' f; do
      base=$(basename -- "$f")
      mv -- "$f" "$dir/archive/"
      if [ "$compress" = yes ]; then
        gzip -f -- "$dir/archive/$base"
      fi
    done
SH
chmod 0755 /usr/local/bin/rotate-logs
