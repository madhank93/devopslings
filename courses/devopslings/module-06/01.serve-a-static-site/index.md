---
kind: lesson
title: "nginx is running, the file is readable, and every request is 403"
description: |
  The site is deployed, nginx is up, and every request returns 403 Forbidden.
  The file is there, it is world-readable, and reading it as root works. The
  permission that is missing is not on the file, and not on the directory the
  file is in.
name: serve-a-static-site
slug: serve-a-static-site
createdAt: "2026-08-22"

sandbox:
  stack: web-stack
  service: web

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop nginx.service 2>/dev/null || true
      rm -rf /srv/www /root/answers/perms.md
      rm -f /etc/nginx/sites-enabled/example /etc/nginx/sites-available/example
      install -d /root/answers

      # ---- the site ----------------------------------------------------
      install -d -m 0755 /srv/www
      install -d -m 0755 /srv/www/example
      install -d -m 0755 /srv/www/example/public

      cat > /srv/www/example/public/index.html <<'HTML'
      <!doctype html>
      <title>example.internal</title>
      <h1>example.internal</h1>
      <p>Served from /srv/www/example/public.</p>
      HTML

      cat > /srv/www/example/public/style.css <<'CSS'
      body { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 40rem; }
      CSS

      chmod 0644 /srv/www/example/public/index.html /srv/www/example/public/style.css

      cat > /etc/nginx/sites-available/example <<'CONF'
      server {
          listen 80 default_server;
          server_name _;

          root /srv/www/example/public;
          index index.html;

          # No try_files: it turns a failed stat into whatever its last argument
          # says, so a permission error on the path is reported as 404 and the
          # symptom stops being the truth. Static delivery here is the default
          # handler, which reports EACCES as 403.
      }
      CONF
      ln -sf /etc/nginx/sites-available/example /etc/nginx/sites-enabled/example

      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service

      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/ && break
        sleep 0.5
      done

      # It has to work before it is broken: a scenario that never served the
      # page would be indistinguishable from the fault below.
      code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1/ || echo 000)
      if [ "$code" != "200" ]; then
        echo "the site did not serve before the fault was applied (got $code)"
        exit 1
      fi

      # ---- the fault ---------------------------------------------------
      #
      # One directory in the middle of the path loses its world execute bit.
      # This is what a release script running with umask 027 leaves behind, and
      # what "lock down the deploy directory" means when it is done to the wrong
      # component of the path.
      #
      # Execute on a directory is permission to *traverse* it — to resolve a
      # name inside it at all. Without it, nothing underneath can be reached,
      # however permissive those files are, and the files here are untouched.
      chmod 0750 /srv/www/example

      cat > /root/questions.txt <<'Q'
      example.internal is deployed and every request returns 403:

        $ curl -si http://127.0.0.1/ | head -1
        HTTP/1.1 403 Forbidden

      nginx is running. The file exists, it is 0644, and reading it as root
      works:

        $ ls -l /srv/www/example/public/index.html
        -rw-r--r-- 1 root root ... /srv/www/example/public/index.html
        $ cat /srv/www/example/public/index.html

      The site was deployed by a script that ran last night. Nobody edited the
      nginx configuration, and `nginx -t` is happy.

      Two things to do.

      1. Make http://127.0.0.1/ serve the page — 200, with the contents of
         /srv/www/example/public/index.html. Leave the site where it is, leave
         the nginx configuration alone, and do not hand the worker process more
         privilege than it has now. Nothing on this box needs to become
         world-writable.

      2. Write /root/answers/perms.md, exactly two lines:

           blocked_path: <path>
           missing_permission: <one word>

         blocked_path is the one component of the path that the worker process
         could not get past. missing_permission is what it was missing there.

      The error log says which file it could not open. The file is not the
      problem — read the whole path, one component at a time, as the user nginx
      actually runs as.
      Q

      echo "scenario ready — nginx up, every request 403"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # ---- the site serves -----------------------------------------------
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || echo 000)
      if [ "$code" != "200" ]; then
        echo "not yet: http://127.0.0.1/ returns $code."
        if [ "$code" = "403" ]; then
          echo "         403 from nginx on a file it can read means the path to the file,"
          echo "         not the file. Walk it as the worker does:"
          echo "         sudo -u www-data namei -l /srv/www/example/public/index.html"
          echo "         and look for the component with no x for that user."
        fi
        exit 1
      fi

      served=$(curl -s -m 5 http://127.0.0.1/ 2>/dev/null || true)
      disk=$(cat /srv/www/example/public/index.html 2>/dev/null || true)
      if [ -z "$disk" ] || [ "$served" != "$disk" ]; then
        echo "not yet: what is served is not the file at"
        echo "         /srv/www/example/public/index.html."
        echo "         Copying the site somewhere the worker can already reach makes the"
        echo "         symptom stop and leaves the deploy directory just as unreachable"
        echo "         for the next release."
        exit 1
      fi

      css=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/style.css 2>/dev/null || echo 000)
      if [ "$css" != "200" ]; then
        echo "not yet: /style.css returns $css, and index.html is served."
        echo "         A fix that reaches one file and not its neighbour is a fix to that"
        echo "         file. The whole directory has to be reachable."
        exit 1
      fi

      # ---- and it serves without giving anything away ---------------------
      if ! grep -qE '^[[:space:]]*root[[:space:]]+/srv/www/example/public;' /etc/nginx/sites-available/example 2>/dev/null; then
        echo "not yet: the site's root is no longer /srv/www/example/public."
        echo "         Pointing nginx at a different directory is not the repair — the"
        echo "         deploy writes to this one."
        exit 1
      fi

      # A missing user directive is one of the outcomes being checked for, so the
      # pipeline must not abort the check under pipefail when grep finds nothing.
      confuser=$(grep -m1 -E '^[[:space:]]*user[[:space:]]+' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';' || true)
      if [ "$confuser" != "www-data" ]; then
        echo "not yet: nginx.conf now runs the workers as '${confuser:-nothing}'."
        echo "         Running the worker as root does serve the page. It also means"
        echo "         every future permission mistake on this box is served too."
        exit 1
      fi

      if pgrep -u root nginx >/dev/null 2>&1 && ! pgrep -u www-data nginx >/dev/null 2>&1; then
        echo "not yet: no nginx worker is running as www-data."
        echo "         The master runs as root and the workers must not."
        exit 1
      fi

      for d in /srv/www /srv/www/example /srv/www/example/public; do
        mode=$(stat -c '%a' "$d" 2>/dev/null || echo 000)
        case "$mode" in
          *[2367])
            echo "not yet: $d is world-writable ($mode)."
            echo "         chmod 777 does open the path. It also lets anything that can"
            echo "         write on this box replace the site. The bit that was missing"
            echo "         was execute, and only execute."
            exit 1
            ;;
        esac
      done

      for f in /srv/www/example/public/index.html /srv/www/example/public/style.css; do
        mode=$(stat -c '%a' "$f" 2>/dev/null || echo 000)
        case "$mode" in
          *[13579]|*[2367])
            echo "not yet: $f is $mode."
            echo "         The files were already readable and were never the problem."
            echo "         Making them executable or writable does not change what the"
            echo "         worker could not do, which was enter the directory above them."
            exit 1
            ;;
        esac
      done

      # ---- naming it -------------------------------------------------------
      if [ ! -s /root/answers/perms.md ]; then
        echo "not yet: /root/answers/perms.md is missing or empty."
        echo "         The page serving is half. The other half is being able to say"
        echo "         which component of the path refused, so the next 403 takes a"
        echo "         minute instead of an afternoon."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/perms.md)
      blocked=$(printf '%s\n' "$low" | sed -n 's#^[[:space:]]*blocked_path[[:space:]]*[:=][[:space:]]*\([^[:space:]]*\).*#\1#p' | head -1)
      perm=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*missing_permission[[:space:]]*[:=][[:space:]]*\([a-z+]*\).*/\1/p' | head -1)
      blocked=${blocked%/}

      if [ -z "$blocked" ]; then
        echo "not yet: no blocked_path line in /root/answers/perms.md."
        exit 1
      fi
      if [ -z "$perm" ]; then
        echo "not yet: no missing_permission line in /root/answers/perms.md."
        exit 1
      fi

      fail=0

      if [ "$blocked" != "/srv/www/example" ]; then
        fail=1
        echo "not yet: you said blocked_path=$blocked."
        case "$blocked" in
          /srv/www/example/public/index.html|/srv/www/example/public/style.css)
            echo "         That file was 0644 the whole time, and root could read it. A"
            echo "         file's own mode is only consulted after every directory above"
            echo "         it has been traversed."
            ;;
          /srv/www/example/public)
            echo "         That directory was 0755 and would have been fine on its own."
            echo "         Resolving a path stops at the first component that refuses,"
            echo "         which is above this one."
            ;;
          /srv/www|/srv|/)
            echo "         That one was 0755 too. Compare the modes along the path:"
            echo "         namei -l /srv/www/example/public/index.html"
            ;;
          *)
            echo "         namei -l /srv/www/example/public/index.html prints every"
            echo "         component with its mode. One of them is the answer."
            ;;
        esac
      fi

      case "$perm" in
        x|+x|execute|search|traverse|o+x) ;;
        *)
          fail=1
          echo "not yet: you said missing_permission=$perm."
          case "$perm" in
            r|read)
              echo "         Read on a directory is permission to list its names. The worker"
              echo "         was not listing it — it was resolving a path through it, and"
              echo "         that is the execute bit."
              ;;
            w|write)
              echo "         Nothing here needed to be written."
              ;;
            *)
              echo "         The word for the bit that lets a process enter a directory and"
              echo "         resolve a name inside it: execute (x), also called the search"
              echo "         bit when it is on a directory."
              ;;
          esac
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the site serves from where it was deployed, the workers still run"
      echo "       as www-data, nothing became world-writable, and the component of"
      echo "       the path that refused is named."
