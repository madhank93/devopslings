#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/assets

cat > assets_test.go <<'GO'
package main

import (
	"encoding/json"
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// mocks records what program() asks for instead of creating it.
type mocks struct {
	mu       sync.Mutex
	acls     []string
	policies []string
}

func (m *mocks) NewResource(a pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	switch a.TypeToken {
	case "minio:index/s3Bucket:S3Bucket":
		acl := "private" // the provider's default
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

func (m *mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) { return a.Args, nil }

// everyone reports whether a policy principal includes "*", in any of the
// shapes IAM accepts: "*", {"AWS": "*"}, {"AWS": ["*"]}.
func everyone(p any) bool {
	switch v := p.(type) {
	case string:
		return v == "*"
	case []any:
		for _, e := range v {
			if everyone(e) {
				return true
			}
		}
	case map[string]any:
		for _, e := range v {
			if everyone(e) {
				return true
			}
		}
	}
	return false
}

func TestBucketIsNotPublic(t *testing.T) {
	m := &mocks{}
	if err := pulumi.RunErr(program, pulumi.WithMocks("assets", "test", m)); err != nil {
		t.Fatal(err)
	}
	for _, acl := range m.acls {
		if acl != "private" {
			t.Errorf("bucket ACL is %q: anyone can read it", acl)
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
			t.Errorf("bucket policy is not valid JSON: %v", err)
			continue
		}
		for _, s := range doc.Statement {
			if s.Effect == "Allow" && everyone(s.Principal) {
				t.Errorf("bucket policy allows everyone: %v", s.Principal)
			}
		}
	}
}
GO

sed -i 's/pulumi.String("public-read")/pulumi.String("private")/' assets.go
go test ./...
