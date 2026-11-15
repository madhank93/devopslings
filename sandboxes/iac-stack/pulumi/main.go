// The module every lesson's program starts from. Building it at image build
// time fills the module and build caches, so a lesson compiles offline and
// without recompiling the SDKs.
package main

import (
	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
	"github.com/pulumi/pulumi-minio/sdk/go/minio"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func program(ctx *pulumi.Context) error {
	_ = config.New(ctx, "")
	if _, err := docker.NewNetwork(ctx, "n", &docker.NetworkArgs{}); err != nil {
		return err
	}
	_, err := minio.NewS3Bucket(ctx, "b", &minio.S3BucketArgs{})
	return err
}

func main() { pulumi.Run(program) }
