// trivy-prune copies the Python advisories out of a Trivy vulnerability
// database, with the vulnerability records they reference, into a much smaller
// one. The full database is 1.4 GB; module 11 only ever scans Python packages.
//
// Advisories published after the cutoff are dropped, so a rebuild months later
// still finds exactly the vulnerabilities the lessons were written against.
package main

import (
	"encoding/json"
	"log"
	"os"
	"strings"

	bolt "go.etcd.io/bbolt"
)

const cutoff = "2026-11-01"

func copyBucket(src, dst *bolt.Bucket, seen map[string]bool, keep func(id []byte) bool, depth int) error {
	return src.ForEach(func(k, v []byte) error {
		if v == nil {
			child, err := dst.CreateBucketIfNotExists(k)
			if err != nil {
				return err
			}
			return copyBucket(src.Bucket(k), child, seen, keep, depth+1)
		}
		// ecosystem bucket -> package bucket -> vulnerability ID
		if depth == 1 {
			if !keep(k) {
				return nil
			}
			seen[string(k)] = true
		}
		return dst.Put(k, v)
	})
}

func main() {
	in, err := bolt.Open(os.Args[1], 0o600, &bolt.Options{ReadOnly: true})
	if err != nil {
		log.Fatal(err)
	}
	out, err := bolt.Open(os.Args[2], 0o644, nil)
	if err != nil {
		log.Fatal(err)
	}
	seen := map[string]bool{}
	err = in.View(func(rtx *bolt.Tx) error {
		vulns := rtx.Bucket([]byte("vulnerability"))
		keep := func(id []byte) bool {
			var v struct{ PublishedDate string }
			_ = json.Unmarshal(vulns.Get(id), &v)
			return len(v.PublishedDate) < 10 || v.PublishedDate[:10] <= cutoff
		}
		return out.Update(func(wtx *bolt.Tx) error {
			err := rtx.ForEach(func(name []byte, b *bolt.Bucket) error {
				n := string(name)
				if !strings.HasPrefix(n, "pip::") && n != "data-source" {
					return nil
				}
				dst, err := wtx.CreateBucket(name)
				if err != nil {
					return err
				}
				return copyBucket(b, dst, seen, keep, 0)
			})
			if err != nil {
				return err
			}
			src := rtx.Bucket([]byte("vulnerability"))
			dst, err := wtx.CreateBucket([]byte("vulnerability"))
			if err != nil {
				return err
			}
			for id := range seen {
				if v := src.Get([]byte(id)); v != nil {
					if err := dst.Put([]byte(id), v); err != nil {
						return err
					}
				}
			}
			return nil
		})
	})
	if err != nil {
		log.Fatal(err)
	}
	if err := out.Close(); err != nil {
		log.Fatal(err)
	}
}
