---
title: "the assets bucket went public, and nothing stopped it"
---

## The situation

`/root/assets` creates `assets`, the MinIO bucket the website's images are
served from, and a policy that lets the image pipeline upload to it. The last
commit changed one word:

```
$ git log --oneline
b71c0d2 assets: serve images straight from the bucket, skip the CDN
5e09a4f assets: private bucket, uploader may write
$ git show HEAD | grep Acl
-		Acl:    pulumi.String("private"),
+		Acl:    pulumi.String("public-read"),
```

Every image, and everything else anyone ever puts in that bucket, is now
readable by anyone who knows the URL. The review passed because the diff is
one line and looks harmless. The first place anyone could have noticed was
production.

A Pulumi program is Go, so it can have Go tests. With `pulumi.WithMocks`,
the program runs against a fake engine. Every `New...` call goes to your mock
instead of a provider, so a test sees exactly what the program asked for,
in milliseconds, with nothing deployed.

## Your objectives

1. Write a Go test in `/root/assets` that fails when `program()` makes the
   bucket public. Public means an ACL other than private, or a bucket policy
   that allows everyone: `"Principal": "*"`, `{"AWS": "*"}` or
   `{"AWS": ["*"]}`.
2. A private bucket must pass, with or without a policy for a named
   principal.
3. The test must use `pulumi.WithMocks`.
4. Then fix `assets.go`, so `go test` passes.

## What you're being graded on

`go test` must pass in `/root/assets`, and a test must use `WithMocks`.

Then the grader swaps in its own versions of `assets.go` and runs your test
against each. It must fail for an ACL of `public-read`, `public-read-write`
and `public`, and for a private bucket with a policy for `"*"`,
`{"AWS": "*"}` or `{"AWS": ["*"]}`. It must pass for a private bucket with the
uploader policy, and for a private bucket with no policy. Every one of those
files mentions `public-read` in a comment, so only a test that runs
`program()` tells them apart.

Last, the grader runs its own test against your `assets.go`, which must make
nothing public.

<details>
<summary>Hint 1 — what a mock sees</summary>

A mock implements two methods. `NewResource` is called once for every
resource the program creates:

```go
func (m *mocks) NewResource(a pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	// a.TypeToken is "minio:index/s3Bucket:S3Bucket" for a bucket
	// a.Inputs["acl"] is what the program set for Acl
	return a.Name + "_id", a.Inputs, nil
}

func (m *mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) { return a.Args, nil }
```

Record what you care about in the mock, then run the program and look:

```go
m := &mocks{}
err := pulumi.RunErr(program, pulumi.WithMocks("assets", "test", m))
```

Input names are the provider's, in camelCase: `acl`, `policy`, `bucket`.

</details>

<details>
<summary>Hint 2 — the principal comes in three shapes</summary>

An IAM principal can be the string `"*"`, a map like `{"AWS": "*"}`, or a map
of lists like `{"AWS": ["*"]}`. A check for one shape lets the other two
through. Unmarshal the policy into `any` and walk it: strings, slices and
maps, looking for a `"*"`.

Also: if the program never sets `Acl`, the input is absent, and MinIO's
default is private.

</details>

<details>
<summary>Hint 3 — why the grader cares how you test</summary>

A test that reads `assets.go` as text and looks for `public-read` passes
this repository today and misses the next variant: an ACL built from a
config value, or a policy assembled with `fmt.Sprintf`. Testing through
`program()` and the mocks checks what the program does, not how it is
spelt.

</details>

<details>
<summary>Solution</summary>

`assets_test.go`:

```go
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

func (m *mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) { return a.Args, nil }

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
```

The mock is a struct with a mutex because Pulumi registers resources from
more than one goroutine. Then put `"private"` back in `assets.go`:

```
$ go test ./...
ok  	assets	0.04s
```

### A test is a review that does not get tired

The diff that made the bucket public was one word, and the person reviewing
it was looking at the CDN change. The test does not care what the commit
says it is for. It runs the program and looks at what it asks for. Run
`go test` in CI before `pulumi preview`, and a public bucket fails the build
before the provider is even started.

</details>
