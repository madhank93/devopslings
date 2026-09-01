#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A secret mount is present only for the duration of the RUN that asks for it:
# it is not a layer, and it is not part of the build args recorded in history.
set -euo pipefail

cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY unpack.py assets.enc app.py ./
RUN --mount=type=secret,id=license \
    python3 unpack.py /run/secrets/license assets.enc /app/assets.txt
CMD ["python3", "app.py"]
DOCKER

cat > build.sh <<'SH'
#!/usr/bin/env bash
# What CI runs. The grader runs this too, so whatever your build needs,
# put it here.
set -euo pipefail
docker build --secret id=license,src=license.key -t devopslings-licensed .
SH
chmod +x build.sh
