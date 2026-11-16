package main

import (
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

type mocks struct{}

func (mocks) NewResource(a pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	return a.Name + "_id", a.Inputs, nil
}

func (mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) { return a.Args, nil }

func TestProgram(t *testing.T) {
	if err := pulumi.RunErr(program, pulumi.WithMocks("p", "s", mocks{})); err != nil {
		t.Fatal(err)
	}
}
