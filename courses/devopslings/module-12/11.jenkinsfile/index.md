---
kind: lesson
title: "the same pipeline, in the tool the enterprise actually runs"
description: |
  A freestyle job with three shell steps builds, tests and publishes — and
  publishes whether or not the tests passed, because the definition lives in
  Jenkins' own config where nobody reviews it. Move it to a Jenkinsfile in the
  repository and make the gate real.
name: jenkinsfile
slug: jenkinsfile
createdAt: "2026-09-04"

sandbox:
  stack: jenkins-stack
  service: jenkins

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      J=http://localhost:8080
      home=/var/jenkins_home
      jar=$(mktemp)

      # Every POST needs a crumb, and the crumb is bound to the session that
      # asked for it — so the cookie jar has to be shared with the fetch.
      crumb() {
        curl -fsS -c "$jar" -b "$jar" "$J/crumbIssuer/api/json" 2>/dev/null \
          | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' || true
      }

      i=0
      while [ "$i" -lt 60 ]; do
        [ "$(curl -s -o /dev/null -w '%{http_code}' "$J/api/json" 2>/dev/null)" = "200" ] && break
        i=$((i + 1))
        sleep 3
      done

      git config --global user.email dev@example.invalid
      git config --global user.name dev
      git config --global init.defaultBranch main
      git config --global --add safe.directory '*'

      rm -rf "$home/repo.git" "$home/checkout" "$home/published"
      mkdir -p "$home/published"

      seed=$(mktemp -d)
      cd "$seed"
      git init -q .

      cat > build.sh <<'SH'
      #!/bin/sh
      # "Build": stamp the commit into an artefact.
      set -eu
      mkdir -p dist
      git rev-parse HEAD > dist/REVISION
      echo "built $(cat dist/REVISION)"
      SH

      cat > tests.sh <<'SH'
      #!/bin/sh
      # The suite. Exits non-zero when it fails, like every suite.
      set -eu
      . ./src/rate.sh
      got=$(discounted 100 10)
      if [ "$got" != "90" ]; then
        echo "FAIL: discounted 100 10 = $got, want 90"
        exit 1
      fi
      echo "ok: discounted 100 10 = 90"
      SH

      cat > publish.sh <<'SH'
      #!/bin/sh
      # "Publish": record what is now released. The grader reads this.
      set -eu
      rev=$(cat dist/REVISION)
      mkdir -p /var/jenkins_home/published
      printf '%s' "$rev" > /var/jenkins_home/published/LAST
      echo "PUBLISHED $rev"
      SH

      mkdir -p src
      cat > src/rate.sh <<'SH'
      discounted() {
        echo $(( $1 - ($1 * $2 / 100) ))
      }
      SH

      chmod +x build.sh tests.sh publish.sh
      git add -A
      git commit -qm "rate service, built and tested by shell"

      git init -q --bare "$home/repo.git"
      git push -q "$home/repo.git" HEAD:main
      git --git-dir="$home/repo.git" symbolic-ref HEAD refs/heads/main
      git clone -q "$home/repo.git" "$home/checkout"

      # The job as it exists today: three shell steps, and the definition lives
      # here in Jenkins rather than in the repository. Note what somebody did to
      # the test step to stop it "blocking releases".
      cat > /tmp/legacy.xml <<'XML'
      <project>
        <description>Builds, tests and publishes the rate service.</description>
        <keepDependencies>false</keepDependencies>
        <properties/>
        <scm class="hudson.plugins.git.GitSCM" plugin="git">
          <configVersion>2</configVersion>
          <userRemoteConfigs>
            <hudson.plugins.git.UserRemoteConfig>
              <url>/var/jenkins_home/repo.git</url>
            </hudson.plugins.git.UserRemoteConfig>
          </userRemoteConfigs>
          <branches>
            <hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec>
          </branches>
          <extensions/>
        </scm>
        <canRoam>true</canRoam>
        <disabled>false</disabled>
        <triggers/>
        <builders>
          <hudson.tasks.Shell><command>./build.sh</command></hudson.tasks.Shell>
          <hudson.tasks.Shell><command>./tests.sh || true</command></hudson.tasks.Shell>
          <hudson.tasks.Shell><command>./publish.sh</command></hudson.tasks.Shell>
        </builders>
        <publishers/>
        <buildWrappers/>
      </project>
      XML

      # And an empty pipeline job, already pointed at a Jenkinsfile on main.
      # It fails until there is one.
      cat > /tmp/pipeline.xml <<'XML'
      <flow-definition plugin="workflow-job">
        <description>The same pipeline, defined in the repository.</description>
        <keepDependencies>false</keepDependencies>
        <properties/>
        <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
          <scm class="hudson.plugins.git.GitSCM" plugin="git">
            <configVersion>2</configVersion>
            <userRemoteConfigs>
              <hudson.plugins.git.UserRemoteConfig>
                <url>/var/jenkins_home/repo.git</url>
              </hudson.plugins.git.UserRemoteConfig>
            </userRemoteConfigs>
            <branches>
              <hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec>
            </branches>
            <extensions/>
          </scm>
          <scriptPath>Jenkinsfile</scriptPath>
          <lightweight>false</lightweight>
        </definition>
        <triggers/>
        <disabled>false</disabled>
      </flow-definition>
      XML

      for job in rate-legacy rate-pipeline; do
        curl -fsS -c "$jar" -b "$jar" -X POST "$J/job/${job}/doDelete" \
          -H "Jenkins-Crumb: $(crumb)" >/dev/null 2>&1 || true
      done

      curl -fsS -c "$jar" -b "$jar" -X POST "$J/createItem?name=rate-legacy" \
        -H 'Content-Type: application/xml' -H "Jenkins-Crumb: $(crumb)" \
        --data-binary @/tmp/legacy.xml >/dev/null
      curl -fsS -c "$jar" -b "$jar" -X POST "$J/createItem?name=rate-pipeline" \
        -H 'Content-Type: application/xml' -H "Jenkins-Crumb: $(crumb)" \
        --data-binary @/tmp/pipeline.xml >/dev/null

      rm -f "$jar"

      echo "scenario ready"
      echo
      echo "  jenkins:  http://localhost:18080   (no login)"
      echo "  repo:     $home/repo.git — your clone is at $home/checkout"
      echo
      echo "  rate-legacy    the freestyle job, three shell steps"
      echo "  rate-pipeline  a pipeline job already reading Jenkinsfile from main"
      echo
      echo "Read what rate-legacy actually does — Configure, or:"
      echo "  curl -s http://localhost:8080/job/rate-legacy/config.xml"
      echo
      echo "Then write the Jenkinsfile that replaces it."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      J=http://localhost:8080
      home=/var/jenkins_home
      jar=$(mktemp)

      crumb() {
        curl -fsS -c "$jar" -b "$jar" "$J/crumbIssuer/api/json" 2>/dev/null \
          | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' || true
      }

      # Trigger rate-pipeline and wait for the build it creates. The build
      # number is read first so a stale result cannot be mistaken for this one.
      run_pipeline() {
        _before=$(curl -fsS "$J/job/rate-pipeline/api/json" 2>/dev/null \
                    | sed -n 's/.*"nextBuildNumber":\([0-9]*\).*/\1/p' || true)
        curl -fsS -c "$jar" -b "$jar" -X POST "$J/job/rate-pipeline/build" \
          -H "Jenkins-Crumb: $(crumb)" >/dev/null 2>&1 || true
        _i=0
        while [ "$_i" -lt 80 ]; do
          _r=$(curl -fsS "$J/job/rate-pipeline/${_before}/api/json" 2>/dev/null \
                 | sed -n 's/.*"result":"\([A-Z]*\)".*/\1/p' || true)
          case "$_r" in SUCCESS|FAILURE|ABORTED|UNSTABLE) printf '%s' "$_r"; return 0 ;; esac
          _i=$((_i + 1))
          sleep 3
        done
        printf '%s' "${_r:-}"
      }

      git config --global user.email grader@example.invalid
      git config --global user.name grader
      git config --global --add safe.directory '*'

      work=$(mktemp -d)
      if ! git clone -q "$home/repo.git" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone $home/repo.git"
        exit 1
      fi
      cd "$work/checkout"
      base_sha=$(git rev-parse HEAD)

      restore() {
        git -C "$work/checkout" push -q --force "$home/repo.git" "${base_sha}:main" >/dev/null 2>&1 || true
        rm -rf "$work"
        rm -f "$jar"
      }
      trap restore EXIT

      if [ ! -f Jenkinsfile ]; then
        echo "not yet: there is no Jenkinsfile on main. The point of moving off the"
        echo "freestyle job is that the pipeline becomes a reviewable file in the"
        echo "repository rather than a form in Jenkins' config."
        exit 1
      fi

      jf=$(cat Jenkinsfile)
      case "$jf" in
        *pipeline*) ;;
        *)
          echo "not yet: Jenkinsfile does not declare a 'pipeline' block. This exercise"
          echo "wants Declarative Pipeline, not a scripted one."
          exit 1
          ;;
      esac
      for stage in build test publish; do
        case "$jf" in
          *"$stage"*) ;;
          *)
            echo "not yet: Jenkinsfile has no '$stage' stage. The freestyle job did three"
            echo "things and the replacement has to do the same three."
            exit 1
            ;;
        esac
      done

      # The legacy job has to stop being a second way to release.
      legacy=$(curl -fsS "$J/job/rate-legacy/api/json" 2>/dev/null || true)
      if [ -n "$legacy" ]; then
        case "$legacy" in
          *'"buildable":false'*) ;;
          *)
            echo "not yet: 'rate-legacy' still exists and is still buildable. Two"
            echo "definitions of one pipeline is the problem you were asked to fix, and"
            echo "the freestyle one is the copy nobody reviews. Disable it or delete it."
            exit 1
            ;;
        esac
      fi

      printf 'grader-probe-healthy\n' >> README.probe
      git add -A
      git commit -qm "grader: a healthy commit"
      git push -q "$home/repo.git" HEAD:main
      good_sha=$(git rev-parse HEAD)

      result=$(run_pipeline)
      if [ "$result" != "SUCCESS" ]; then
        echo "not yet: rate-pipeline reported '${result:-nothing}' on a commit whose"
        echo "tests pass. A pipeline that cannot go green does not replace anything."
        exit 1
      fi

      published=$(cat "$home/published/LAST" 2>/dev/null || true)
      if [ "$published" != "$good_sha" ]; then
        echo "not yet: the build succeeded but ${good_sha} was not published —"
        echo "published/LAST holds '${published:-nothing}'. Reproducing the freestyle"
        echo "job means reproducing all three steps, publish included."
        exit 1
      fi

      # And the half the freestyle job got wrong: a failing suite must stop the
      # release, not be stepped over on the way to it.
      sed -i 's/echo $(( $1 - ($1 \* $2 \/ 100) ))/echo $(( $1 - ($1 * $2 \/ 50) ))/' src/rate.sh
      if ! grep -q '50' src/rate.sh; then
        echo "not yet: the grader could not break src/rate.sh — has it moved?"
        exit 1
      fi
      git add -A
      git commit -qm "grader: break the rate calculation"
      git push -q "$home/repo.git" HEAD:main
      bad_sha=$(git rev-parse HEAD)

      result=$(run_pipeline)
      published_after=$(cat "$home/published/LAST" 2>/dev/null || true)

      cd /
      restore
      trap - EXIT

      if [ "$result" != "FAILURE" ]; then
        echo "not yet: a commit whose tests genuinely fail reported '${result:-nothing}'."
        echo "The freestyle job ran './tests.sh || true', which is how it published"
        echo "broken builds for months. A stage that cannot fail is not a gate."
        exit 1
      fi

      if [ "$published_after" = "$bad_sha" ]; then
        echo "not yet: the build failed and ${bad_sha} was published anyway."
        echo "In Declarative Pipeline the stages after a failing one do not run — unless"
        echo "the failure was swallowed inside the stage, which puts you back where the"
        echo "freestyle job was."
        exit 1
      fi

      echo "PASS — the pipeline is a file in the repository, it publishes a healthy"
      echo "commit, and a failing suite stops the release."
---
