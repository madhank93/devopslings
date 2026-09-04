#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The pipeline becomes a file in the repository, and the test stage is allowed
# to fail: Declarative Pipeline stops at the first failing stage, so publish
# simply does not run. The freestyle job is disabled so there is one definition
# of how this service is released.
set -euo pipefail

J=http://localhost:8080
home=/var/jenkins_home
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

crumb() {
  curl -fsS -c "$jar" -b "$jar" "$J/crumbIssuer/api/json" 2>/dev/null \
    | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' || true
}

git config --global user.email dev@example.invalid
git config --global user.name dev
git config --global --add safe.directory '*'

work=$(mktemp -d)
git clone -q "$home/repo.git" "$work/checkout"
cd "$work/checkout"

cat > Jenkinsfile <<'JF'
pipeline {
  agent any

  stages {
    stage('build') {
      steps {
        sh './build.sh'
      }
    }

    stage('test') {
      steps {
        // No `|| true`. The stage fails, and Declarative Pipeline does not
        // run the stages after it — which is the whole gate.
        sh './tests.sh'
      }
    }

    stage('publish') {
      steps {
        sh './publish.sh'
      }
    }
  }
}
JF

git add -A
git commit -qm "define the pipeline in the repository"
git push -q "$home/repo.git" HEAD:main

# One definition of the pipeline. The freestyle job stays for its build history
# but can no longer release anything.
curl -fsS -c "$jar" -b "$jar" -X POST "$J/job/rate-legacy/disable" \
  -H "Jenkins-Crumb: $(crumb)" >/dev/null 2>&1 || true

rm -rf "$work"
echo "Jenkinsfile pushed; rate-legacy disabled"
