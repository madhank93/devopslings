---
kind: lesson
title: "the assets bucket went public, and nothing stopped it"
description: |
  A one-line change made the assets bucket readable by anyone, and the first
  place it could have been noticed was production. Write a unit test that
  fails on a public bucket using Pulumi's mocks, so it runs before anything
  is created, then fix the bucket.
name: unit-testing-infrastructure
slug: unit-testing-infrastructure
createdAt: "2026-11-13"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      rm -rf /root/assets /var/lib/devopslings/unit-testing-infrastructure
      install -d /root/assets /var/lib/devopslings
      cd /root/assets

      cp /opt/pulumi-template/go.mod /opt/pulumi-template/go.sum .
      sed -i 's/^module program$/module assets/' go.mod
      cat > Pulumi.yaml <<'YAML'
      name: assets
      runtime: go
      description: the bucket the website's images are served from
      backend:
        url: file:///var/lib/pulumi/assets
      YAML
      cat > main.go <<'GO'
      package main

      import "github.com/pulumi/pulumi/sdk/v3/go/pulumi"

      func main() { pulumi.Run(program) }
      GO
      cat > assets.go <<'GO'
      package main

      import (
      	"github.com/pulumi/pulumi-minio/sdk/go/minio"
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
      )

      // uploaderPolicy lets the image pipeline write to the bucket, and nobody
      // else anything.
      const uploaderPolicy = `{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"AWS": ["arn:aws:iam::000000000000:user/uploader"]},
          "Action": ["s3:PutObject"],
          "Resource": ["arn:aws:s3:::assets/*"]
        }]
      }`

      // program is the whole deployment: the assets bucket and who may use it.
      func program(ctx *pulumi.Context) error {
      	bucket, err := minio.NewS3Bucket(ctx, "assets", &minio.S3BucketArgs{
      		Bucket: pulumi.String("assets"),
      		Acl:    pulumi.String("public-read"),
      	})
      	if err != nil {
      		return err
      	}
      	_, err = minio.NewS3BucketPolicy(ctx, "assets-uploader", &minio.S3BucketPolicyArgs{
      		Bucket: bucket.Bucket,
      		Policy: pulumi.String(uploaderPolicy),
      	})
      	return err
      }
      GO
      git init -q
      sed 's/"public-read"/"private"/' assets.go > assets.go.orig && mv assets.go.orig assets.go
      git add -A && git commit -qm "assets: private bucket, uploader may write"
      sed -i 's/"private"/"public-read"/' assets.go
      git commit -qam "assets: serve images straight from the bucket, skip the CDN"

      cat > README <<'TXT'
      The last commit made the assets bucket public-read. Nobody noticed until
      it was live. Make sure that cannot happen again:

        - write a Go test (assets_test.go, or any *_test.go here) that fails
          when program() makes the bucket public: a public ACL, or a bucket
          policy that allows everyone ("Principal": "*", or {"AWS": "*"} or
          {"AWS": ["*"]}). A bucket that is private, with or without a policy
          for a named principal, must pass.
        - the test uses pulumi.WithMocks, so nothing is deployed and no
          provider or server is needed
        - then fix assets.go, so go test passes

      The check swaps assets.go for its own versions, some public and some
      not, and runs your test against each. So test through program(), and
      keep everything the test needs in the test file.
      TXT
      echo "scenario ready — /root/assets makes a public bucket and has no test"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      if ! cd /root/assets 2>/dev/null || [ ! -f assets.go ]; then
        echo "not yet: /root/assets/assets.go is gone — reset the lesson"
        exit 1
      fi
      if ! grep -q '^func program(ctx \*pulumi.Context) error' assets.go; then
        echo "not yet: assets.go no longer defines func program(ctx *pulumi.Context) error."
        echo "         The check swaps assets.go for its own versions and calls program()"
        exit 1
      fi
      tests=$(ls ./*_test.go 2>/dev/null || true)
      if [ -z "$tests" ]; then
        echo "not yet: there is no *_test.go in /root/assets"
        exit 1
      fi
      if ! grep -qs 'WithMocks' ./*_test.go; then
        echo "not yet: no test uses pulumi.WithMocks. Without mocks a test needs a real"
        echo "         provider and server, so it can only tell you after the bucket exists"
        exit 1
      fi

      work=/var/lib/devopslings/unit-testing-infrastructure
      # gotest <dir>: compile then run the tests there; prints "build", "fail" or "pass".
      gotest() {
        if ! (cd "$1" && go test -count=1 -run '^$' . >"$1/.build.log" 2>&1); then echo build; return; fi
        if (cd "$1" && go test -count=1 . >"$1/.test.log" 2>&1); then echo pass; else echo fail; fi
      }

      # ---- 1. the student's own tree ---------------------------------------------
      rm -rf "$work"
      install -d "$work"
      r=$(gotest /root/assets)
      if [ "$r" != pass ]; then
        echo "not yet: go test fails in /root/assets:"
        grep -h -m4 -E '\.go:[0-9]+|FAIL|--- ' /root/assets/.test.log /root/assets/.build.log 2>/dev/null | sed 's/^/         /' || true
        rm -f /root/assets/.test.log /root/assets/.build.log
        exit 1
      fi
      rm -f /root/assets/.test.log /root/assets/.build.log

      # ---- 2. the student's test, against the check's versions of assets.go ------
      good='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["arn:aws:iam::000000000000:user/uploader"]},"Action":["s3:PutObject"],"Resource":["arn:aws:s3:::assets/*"]}]}'
      star='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::assets/*"]}]}'
      awsstar='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::assets/*"]}]}'
      awsstr='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::assets/*"]}]}'
      # variant <name> <acl> <policy or empty>: a copy of the project with that assets.go.
      variant() {
        local d="$work/$1"
        install -d "$d"
        cp go.mod go.sum ./*.go "$d/"
        {
          echo 'package main'
          echo
          echo 'import ('
          echo '	"github.com/pulumi/pulumi-minio/sdk/go/minio"'
          echo '	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"'
          echo ')'
          echo
          # Every variant mentions the public forms, so a test that greps the
          # source instead of running program() fails the private ones.
          echo '// Not public-read, and no "Principal": "*".'
          echo 'func program(ctx *pulumi.Context) error {'
          echo '	bucket, err := minio.NewS3Bucket(ctx, "assets", &minio.S3BucketArgs{'
          echo '		Bucket: pulumi.String("assets"),'
          echo "		Acl:    pulumi.String(\"$2\"),"
          echo '	})'
          echo '	if err != nil {'
          echo '		return err'
          echo '	}'
          if [ -n "$3" ]; then
            echo '	_, err = minio.NewS3BucketPolicy(ctx, "assets-policy", &minio.S3BucketPolicyArgs{'
            echo '		Bucket: bucket.Bucket,'
            echo "		Policy: pulumi.String(\`$3\`),"
            echo '	})'
          else
            echo '	_ = bucket'
          fi
          echo '	return err'
          echo '}'
        } > "$d/assets.go"
        echo "$d"
      }
      while IFS='|' read -r name acl pol want what; do
        case "$pol" in good) pol=$good ;; star) pol=$star ;; awsstar) pol=$awsstar ;; awsstr) pol=$awsstr ;; esac
        d=$(variant "$name" "$acl" "$pol")
        r=$(gotest "$d")
        if [ "$r" = build ]; then
          echo "not yet: your test does not compile against the check's own assets.go:"
          grep -m3 -E '\.go:[0-9]+' "$d/.build.log" | sed 's/^/         /' || true
          echo "         keep everything the test needs in the test file, and test through program()"
          exit 1
        fi
        if [ "$r" != "$want" ]; then
          if [ "$want" = fail ]; then
            echo "not yet: your test passes when $what."
            echo "         That bucket is readable by anyone, so the test should fail"
          else
            echo "not yet: your test fails when $what."
            echo "         Nothing is public there, so it should pass:"
            grep -m3 -E '_test\.go:[0-9]+' "$d/.test.log" | sed 's/^/           /' || true
            sed -i '/^\/\/ Not public-read/d' "$d/assets.go"
            if [ "$(gotest "$d")" = pass ]; then
              echo "         It passes once the comment naming public-read and \"Principal\": \"*\" is"
              echo "         removed from that assets.go, so the test reads the source as text."
              echo "         Test what program() creates, through the mocks"
            fi
          fi
          exit 1
        fi
      done <<'CASES'
      acl-public-read|public-read||fail|the bucket's ACL is public-read
      acl-public-read-write|public-read-write||fail|the bucket's ACL is public-read-write
      acl-public|public||fail|the bucket's ACL is public
      policy-star|private|star|fail|the bucket is private and a policy allows "Principal": "*"
      policy-aws-star|private|awsstar|fail|the bucket is private and a policy allows {"AWS": ["*"]}
      policy-aws-str|private|awsstr|fail|the bucket is private and a policy allows {"AWS": "*"}
      private-uploader|private|good|pass|the bucket is private with a policy for one named uploader
      private-bare|private||pass|the bucket is private with no policy at all
      CASES

      # ---- 3. the student's own assets.go, by the check's test -------------------
      d="$work/own"
      install -d "$d"
      cp go.mod go.sum main.go assets.go "$d/"
      cat > "$d/grader_test.go" <<'GO'
      package main

      import (
      	"encoding/json"
      	"sync"
      	"testing"

      	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
      )

      type graderMocks struct {
      	mu       sync.Mutex
      	acls     []string
      	policies []string
      }

      func (m *graderMocks) NewResource(a pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
      	m.mu.Lock()
      	defer m.mu.Unlock()
      	switch a.TypeToken {
      	case "minio:index/s3Bucket:S3Bucket":
      		acl := "private"
      		if v, ok := a.Inputs["acl"]; ok && v.IsString() {
      			acl = v.StringValue()
      		}
      		m.acls = append(m.acls, acl)
      	case "minio:index/s3BucketPolicy:S3BucketPolicy":
      		if v, ok := a.Inputs["policy"]; ok && v.IsString() {
      			m.policies = append(m.policies, v.StringValue())
      		}
      	}
      	return a.Name + "_id", a.Inputs, nil
      }

      func (m *graderMocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) { return a.Args, nil }

      func graderStar(v any) bool {
      	switch x := v.(type) {
      	case string:
      		return x == "*"
      	case []any:
      		for _, e := range x {
      			if graderStar(e) {
      				return true
      			}
      		}
      	case map[string]any:
      		for _, e := range x {
      			if graderStar(e) {
      				return true
      			}
      		}
      	}
      	return false
      }

      func TestGraderNotPublic(t *testing.T) {
      	m := &graderMocks{}
      	if err := pulumi.RunErr(program, pulumi.WithMocks("assets", "dev", m)); err != nil {
      		t.Fatal(err)
      	}
      	for _, acl := range m.acls {
      		if acl != "private" {
      			t.Errorf("ACL %s", acl)
      		}
      	}
      	for _, p := range m.policies {
      		var doc struct {
      			Statement []struct {
      				Effect    string
      				Principal any
      			}
      		}
      		if err := json.Unmarshal([]byte(p), &doc); err != nil {
      			t.Errorf("unreadable policy")
      			continue
      		}
      		for _, s := range doc.Statement {
      			if s.Effect == "Allow" && graderStar(s.Principal) {
      				t.Errorf("a policy allows everyone")
      			}
      		}
      	}
      }
      GO
      if ! (cd "$d" && go test -count=1 -run '^TestGraderNotPublic$' . >"$d/.test.log" 2>&1); then
        echo "not yet: your test is right, and assets.go still makes the bucket public:"
        grep -E 'grader_test\.go:[0-9]+' "$d/.test.log" | sed 's/.*grader_test\.go:[0-9]*: /           /' | sort -u || true
        exit 1
      fi
      rm -rf "$work"
      echo "PASS — the test fails on every public bucket and passes on private ones, without"
      echo "       deploying anything, and assets.go is private again."
---
