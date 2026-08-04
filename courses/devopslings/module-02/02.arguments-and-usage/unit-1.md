---
title: "three positional arguments and nobody remembers the order"
---

## The situation

```
$ head -2 /usr/local/bin/rotate-logs
#!/bin/bash
# rotate-logs <dir> <days> <compress>
```

The only documentation is a comment in the file. To use it you have to open it.
To use it correctly you have to open it and read carefully, because getting the
order wrong is not an error:

```
$ rotate-logs 7 /srv/logs yes
```

That is `dir=7`, `days=/srv/logs`. It will not complain about either.

## Your objective

Rewrite `/usr/local/bin/rotate-logs` to take named flags:

| flag | behaviour |
|---|---|
| `--dir <path>` | **required**. Missing → message naming it on stderr, non-zero exit |
| `--days <n>` | optional, **default 7** |
| `--compress` | optional switch, off by default |
| `-h`, `--help` | usage listing the flags, exit 0 |

An unknown flag must be rejected: stderr message, non-zero exit.

Keep the behaviour — files older than `--days` move into `<dir>/archive`, newer
ones are untouched.

## What you're being graded on

`--help` and `-h` both work and mention every flag. No arguments exits non-zero
with a message naming `--dir`. An unknown flag is refused. `--dir` alone
archives 4 and leaves 3 with nothing compressed. `--dir --days 1 --compress`
produces 4 `.gz`.

<details>
<summary>Hint 1 — parsing a flag loop</summary>

```bash
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)      dir=$2;      shift 2 ;;
    --days)     days=$2;     shift 2 ;;
    --compress) compress=yes; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
```

`shift 2` for flags taking a value, `shift` for switches. `$#` counts what is
left, so the loop ends on its own.

`getopts` is the built-in alternative and handles short options well, but does
not do long options like `--dir` portably. A `case` loop is clearer for a script
this size, and does not need explaining to whoever reads it next.

</details>

<details>
<summary>Hint 2 — defaults belong in one visible place</summary>

```bash
dir=""
days=7
compress=no
```

Set them before parsing, then let flags override. The default is then a fact
you can read at the top of the file rather than something implied by what
happens when an argument is absent.

Under `set -u` an unset variable is an error, so initialising everything is
required as well as tidy — and `${2:-}` when reading a flag's value stops a
missing final argument from aborting with an unhelpful message.

</details>

<details>
<summary>Hint 3 — validate before doing anything, and say what is wrong</summary>

```bash
if [ -z "$dir" ]; then
  printf 'rotate-logs: --dir is required\n\n' >&2
  usage >&2
  exit 2
fi
```

Three properties worth having:

- **Name what is missing.** "usage: ..." alone makes the reader diff their
  command against the synopsis. "`--dir` is required" does not.
- **Errors to stderr.** So `rotate-logs ... > out.txt` still shows the problem,
  and so a caller can separate the two streams.
- **Validate before acting.** Check `--days` is a number *before* the first
  `mv`. Half-run destructive scripts are how a bad argument becomes an
  incident.

And reject unknown flags. A typo'd `--compres` that is silently ignored means
the script runs with a default nobody chose, and nothing says so.

</details>

<details>
<summary>Solution</summary>

```bash
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

dir=""
days=7
compress=no

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)      dir=${2:-};   shift 2 ;;
    --days)     days=${2:-};  shift 2 ;;
    --compress) compress=yes; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    -*)         printf 'rotate-logs: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *)          printf 'rotate-logs: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$dir" ] || { printf 'rotate-logs: --dir is required\n\n' >&2; usage >&2; exit 2; }
[ -d "$dir" ] || { printf 'rotate-logs: --dir %s: not a directory\n' "$dir" >&2; exit 2; }
case "$days" in ''|*[!0-9]*) printf 'rotate-logs: --days must be a whole number\n' >&2; exit 2 ;; esac

mkdir -p "$dir/archive"
find "$dir" -maxdepth 1 -type f -name '*.log' -mtime +"$days" -print0 \
  | while IFS= read -r -d '' f; do
      base=$(basename -- "$f")
      mv -- "$f" "$dir/archive/"
      [ "$compress" = yes ] && gzip -f -- "$dir/archive/$base"
    done
```

### Why this is a lesson at all

This is the only `intro` exercise in the module where nothing is broken. The
script works. It is just impossible to use safely, and that is a defect with
consequences — `rotate-logs` deletes things, and its interface offers no way to
find out what it is about to do.

Three properties that make a script safe for someone who is not its author:

1. **Named arguments are self-documenting at the call site.** `rotate-logs
   --dir /srv/logs --days 30` can be read in a cron file, a runbook or an
   incident timeline without opening the script. `rotate-logs /srv/logs 30 yes`
   cannot — and the reader of a postmortem is usually not the author.

2. **Defaults must be visible and overridable.** In one place at the top, not
   implied by position or by what an empty variable happens to do.

3. **Refuse rather than assume.** A missing required argument and an unknown
   flag both mean the caller believed something untrue. Continuing with a
   default converts their misunderstanding into your incident.

The `--help` output is the interface. If it is wrong or absent, the interface is
the source code.

</details>
