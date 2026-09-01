#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two halves of one fix: ask for both platforms, and tell the compiler which one
# each pass is for. The builder stage stays on the build machine, which is what
# makes the build fast; TARGETARCH is what makes it correct.
set -euo pipefail

cat > Dockerfile <<'DOCKER'
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /out/app main.go

FROM alpine:3.20
COPY --from=build /out/app /usr/local/bin/app
CMD ["app"]
DOCKER

cat > build.sh <<'SH'
#!/usr/bin/env bash
# What CI runs to publish the agent. The grader runs this too.
set -euo pipefail
docker buildx build --builder devopslings-xarch \
  --platform linux/amd64,linux/arm64 \
  --push -t localhost:5001/pricing-agent:1 .
SH
chmod +x build.sh
