#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# The fix is one build, whose digest is promoted by re-tagging.
# Neither deploy job builds anything.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

cat > .forgejo/workflows/ci.yml <<'YAML'
name: ci

on: [push]

env:
  IMAGE: 127.0.0.1:5000/checkout

jobs:
  build:
    runs-on: docker
    container:
      image: docker:27-cli
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          docker build --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%S)-$$" \
            -t "${IMAGE}:git-${{ github.sha }}" .
          docker push "${IMAGE}:git-${{ github.sha }}"

  deploy-staging:
    runs-on: docker
    needs: [build]
    container:
      image: docker:27-cli
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          docker pull "${IMAGE}:git-${{ github.sha }}"
          docker tag "${IMAGE}:git-${{ github.sha }}" "${IMAGE}:staging"
          docker push "${IMAGE}:staging"

  deploy-production:
    runs-on: docker
    needs: [deploy-staging]
    container:
      image: docker:27-cli
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          docker pull "${IMAGE}:git-${{ github.sha }}"
          docker tag "${IMAGE}:git-${{ github.sha }}" "${IMAGE}:production"
          docker push "${IMAGE}:production"
YAML

git add -A
git commit -qm "build once and promote the digest to each environment"
git push -q origin main
