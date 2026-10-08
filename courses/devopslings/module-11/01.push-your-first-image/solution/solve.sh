#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Two builds, each pushed under a version and under latest; each digest is
# read back from the registry rather than from the local daemon.
set -euo pipefail

reg=127.0.0.1:15000
echo devopslings | docker login "$reg" -u devops --password-stdin >/dev/null 2>&1

cd /work/hello
docker build -q -t "$reg/hello/web:1.0" -t "$reg/hello/web:latest" . >/dev/null
docker push -q "$reg/hello/web:1.0" >/dev/null
docker push -q "$reg/hello/web:latest" >/dev/null
first=$(crane digest "$reg/hello/web:latest")

echo '<h1>hello, version two</h1>' > index.html
docker build -q -t "$reg/hello/web:1.1" -t "$reg/hello/web:latest" . >/dev/null
docker push -q "$reg/hello/web:1.1" >/dev/null
docker push -q "$reg/hello/web:latest" >/dev/null
second=$(crane digest "$reg/hello/web:latest")

sed -i "s/^first=.*/first=$first/; s/^second=.*/second=$second/" /work/answer.txt
