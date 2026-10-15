# sops + age + git, for module 16. Two consumers: a workflow job uses it as its
# container image, and a student without the tools installed runs them through
# it. Baked at `up` time so neither needs the internet at grade time.
FROM alpine:3.20

ARG SOPS_VERSION=3.10.2
ARG AGE_VERSION=1.2.1
ARG TARGETARCH

RUN apk add --no-cache git curl \
 && case "$TARGETARCH" in \
      amd64) sops_sum=79b0f844237bd4b0446e4dc884dbc1765fc7dedc3968f743d5949c6f2e701739 \
             age_sum=7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50 ;; \
      arm64) sops_sum=e91ddc04e6a78f5aed9e4fc347a279b539c43b74d99e6b8078e2f2f6f5b309f5 \
             age_sum=57fd79a7ece5fe501f351b9dd51a82fbee1ea8db65a8839db17f5c080245e99f ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSLo /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" \
 && echo "${sops_sum}  /usr/local/bin/sops" | sha256sum -c - \
 && chmod +x /usr/local/bin/sops \
 && curl -fsSLo /tmp/age.tgz \
      "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && echo "${age_sum}  /tmp/age.tgz" | sha256sum -c - \
 && tar -xzf /tmp/age.tgz -C /usr/local/bin --strip-components=1 age/age age/age-keygen \
 && rm /tmp/age.tgz \
 && sops --version --disable-version-check && age --version
