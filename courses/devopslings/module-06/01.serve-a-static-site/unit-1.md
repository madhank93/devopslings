---
title: "nginx is running, the file is readable, and every request is 403"
---

## The situation

```
$ curl -si http://127.0.0.1/ | head -1
HTTP/1.1 403 Forbidden
```

nginx is up. `nginx -t` is happy. Nobody has touched the configuration. And the
file it is refusing to serve is right there, readable by everyone:

```
$ ls -l /srv/www/example/public/index.html
-rw-r--r-- 1 root root 118 Aug 22 09:14 /srv/www/example/public/index.html
$ cat /srv/www/example/public/index.html
<!doctype html>
...
```

Two facts that appear to contradict each other. They do not, and the reason is
the most useful thing in this lesson.

## 403 is a sentence with a subject

`403 Forbidden` from a web server is shorthand for: *the process that tried to
open this file was not allowed to*. Three parts of that sentence are usually
skipped over, and each is where the answer hides.

**The process.** Not you. nginx's master runs as root and immediately drops to
an unprivileged user for the workers — `www-data` on Debian — because a worker
is the part that touches attacker-supplied input. `cat` as root proves nothing
about what a worker can do. It is the wrong user asking the wrong question.

**The file.** Or rather, not the file. Which brings us to the third part.

**Was not allowed to.** Opening `/srv/www/example/public/index.html` is not one
permission check. It is one check per component of the path:

```
/srv                            can I traverse this?
/srv/www                        can I traverse this?
/srv/www/example                can I traverse this?
/srv/www/example/public         can I traverse this?
/srv/www/example/public/index.html   can I read this?
```

The kernel walks that list in order and stops at the first refusal. The file's
own mode is consulted last, and only if every directory above it said yes. A
`-rw-r--r--` file inside a directory you cannot enter is exactly as unreachable
as a file that does not exist — and `ls -l` on the file, which is the first
thing everyone runs, cannot show you that.

## Execute on a directory is not "run it"

On a regular file, the execute bit means what it sounds like. On a directory it
means something else entirely: **permission to traverse** — to resolve a name
inside it. It is often called the *search* bit for that reason.

The consequences are worth having straight, because they are not symmetric:

| bits on a directory | what a process can do |
|---|---|
| `r--` | list the names in it, and nothing else — `ls` works, opening anything inside fails |
| `--x` | open things inside it *by name*, but not list what is there |
| `r-x` | both: the normal case for a directory anyone should be able to read |

A web root wants `r-x` for others. `--x` alone is a real pattern too: it is how
a directory of per-user files stays private in aggregate while each user can
still open their own path.

The tool that shows the whole walk at once:

```
$ namei -l /srv/www/example/public/index.html
f: /srv/www/example/public/index.html
 drwxr-xr-x root root /
 drwxr-xr-x root root srv
 drwxr-xr-x root root www
 drwxr-x--- root root example      <-- no x for others
 drwxr-xr-x root root public
 -rw-r--r-- root root index.html
```

One line has no `x` in the last triad. That is the whole fault.

And the way to ask the question as the process that is actually failing:

```
$ sudo -u www-data cat /srv/www/example/public/index.html
cat: ...: Permission denied
$ sudo -u www-data ls /srv/www/example/
ls: cannot open directory: Permission denied
```

nginx's own error log says the same thing, in its own words:

```
$ tail -1 /var/log/nginx/error.log
... [error] open() "/srv/www/example/public/index.html" failed (13: Permission denied)
```

Note what that log line does *not* say: which component refused. It names the
file, because the file is what nginx asked for. Reading it as "the file's
permissions are wrong" is the single most common wrong turn here.

## How a directory ends up like this

Nobody types `chmod 0750` on a release directory on purpose. It arrives two
ways, both boring:

- **A umask.** A deploy script running with `umask 027` creates every directory
  it makes without the world execute bit. The files inside look fine. The
  directory does not, and only for users outside the group.
- **"Lock down the deploy directory".** Someone tightens permissions on a
  parent, tests it as root or as the deploy user — both of which are in the
  group, or are the owner — and never as the account the web server runs as.

Both produce a site that works for everyone who checks it by hand and 403s for
the only user that matters.

## Your objective

1. Make `http://127.0.0.1/` serve the page: 200, with the contents of
   `/srv/www/example/public/index.html`. Leave the site where it is, leave the
   nginx configuration alone, and do not hand the worker more privilege than it
   has. Nothing needs to become world-writable.

2. Write `/root/answers/perms.md`, exactly two lines:

   ```
   blocked_path: <path>
   missing_permission: <one word>
   ```

## What you're being graded on

**The page serves, and so does its neighbour.** `/style.css` is checked as well
as `/index.html`, because a fix that reaches one file and not the other is a
fix applied to a file rather than to the path.

**It is the deployed site being served.** The response body is compared with
the file on disk at the original path. Copying the site somewhere reachable
makes the symptom stop and leaves the next release just as broken.

**Nothing was given away to get there.** Four things are checked by name, and
all four "work":

- the workers still run as `www-data` — running them as root serves this page
  and every future permission mistake on the box
- the site root in the nginx config is unchanged
- no directory in the path is world-writable — `chmod 777` opens the path and
  also lets anything on the box replace the site
- the files are not made writable or executable — they were never the problem,
  and changing them says you have not found it yet

**You can name the component.** `/srv/www/example`, and the bit is execute.

<details>
<summary>Hint 1 — ask as the right user</summary>

Every check you run as root answers a question nobody asked. The failing
process is a worker running as `www-data`:

```
$ ps -o pid,user,args -C nginx
$ sudo -u www-data cat /srv/www/example/public/index.html
```

</details>

<details>
<summary>Hint 2 — read the whole path, not the file</summary>

```
$ namei -l /srv/www/example/public/index.html
```

One line per component, each with its mode. Look at the last triad — the
permissions for "others", which is what `www-data` is here — and find the
directory with no `x`.

</details>

<details>
<summary>Hint 3 — put back only what was taken</summary>

The missing bit is execute, for others, on one directory. `chmod 755` on it
would also work and would grant read as well; `chmod o+x` grants exactly what
was missing and nothing else. `chmod -R` is the wrong instinct here — the
files below were never involved.

</details>

## What actually happened

`/srv/www/example` was `drwxr-x---`. Everything above and below it was
`drwxr-xr-x`, and both files were `-rw-r--r--`.

`www-data` is not the owner and not in the group, so it fell to the last triad
— `---` — and the path walk stopped there. It could not enter the directory, so
it could never get as far as consulting `public`, and never as far as the file
whose permissions everyone was staring at.

The repair is `chmod o+x /srv/www/example`. One bit, on one directory, chosen
by reading the path rather than the file.

<details>
<summary>Solution</summary>

```bash
$ namei -l /srv/www/example/public/index.html   # find the component with no x
$ chmod o+x /srv/www/example
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
200
$ printf 'blocked_path: /srv/www/example\nmissing_permission: execute\n' \
    > /root/answers/perms.md
```

</details>

## Carrying this forward

- **A 403 on a readable file is a path problem.** Always. The file's mode is the
  last check, not the first.
- **Reproduce as the failing user.** `sudo -u <user>` turns an argument about
  what *should* work into an observation. Most permission debugging is people
  testing as an account that was never going to fail.
- **`namei -l` is the whole answer in one command.** It is worth remembering the
  name of, because the alternative is `ls -ld` on five paths.
- **Execute on a directory means traverse.** Read means list. They are different
  permissions with different consequences, and a web root needs both.
- **`try_files` can hide this.** With `try_files $uri $uri/ =404` in the
  location block, the same broken path returns **404**, not 403 — nginx cannot
  stat the file, treats it as absent, and serves the fallback. A 404 for a file
  you can see on disk is the same lesson wearing a different number.
- **`chmod 777` is a diagnosis, not a fix.** If opening everything makes it work,
  you have learned it is a permission — you have not learned which one, and you
  have made the box worse while not learning it.
