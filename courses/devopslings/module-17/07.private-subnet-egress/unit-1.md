---
title: "out to the internet, and no way back in"
---

## The situation

The billing VPC (`10.30.0.0/16`) has a public subnet (`10.30.0.0/24`), whose
route table sends `0.0.0.0/0` to the internet gateway, and a private subnet
(`10.30.1.0/24`), whose route table knows only the VPC. `batch-1`
(`10.30.1.15`) sits in the private subnet. It runs the nightly settlement job,
which has to call the payment provider at `203.0.113.10:443`. It cannot.

The first idea is to give `batch-1` an Elastic IP, point the private subnet
at the internet gateway, and keep the security group tight. That works, and
`batch-1` is now an address on the internet. The only thing between it and
every scanner is one security group, which someone will widen one day to
debug something.

An **internet gateway** translates between a public address and a private
one, in both directions. Without a public address, it has nothing to
translate to. A **NAT gateway** lives in a public subnet, with an address of
its own. It translates outbound connections to that address and accepts no
new inbound ones. A subnet is private when its route to the internet goes
through one.

floci stores routes and gateways but moves no packets. `/root/egress/path`
follows `batch-1`'s traffic out, and the internet's in, the way AWS routes
it.

## Your objectives

1. `batch-1` reaches `203.0.113.10:443`.
2. `batch-1` has no public address, and the private subnet does not give new
   interfaces one.
3. The private subnet's traffic to the internet leaves by a NAT gateway,
   which leaves by the internet gateway.

## What you're being graded on

The grader follows the same path `./path` does. `batch-1` must have no
Elastic IP and the private subnet must not have `MapPublicIpOnLaunch` set.
The private subnet's route for `203.0.113.10` must lead to a public NAT
gateway, and the NAT gateway's own subnet must route to the internet gateway.

<details>
<summary>Hint 1 — where the route goes</summary>

The private subnet has its own route table, `private`. A route added to the
VPC's main table does not apply to it. `./path` prints which table the lookup
used.

</details>

<details>
<summary>Hint 2 — where the NAT gateway goes</summary>

A NAT gateway forwards traffic using the route table of the subnet it sits
in. Put it in the private subnet and its next hop for the internet is itself.
It belongs in the public subnet, and needs an Elastic IP of its own:
`aws ec2 allocate-address --domain vpc`.

</details>

<details>
<summary>Solution</summary>

```
pub=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=public \
  --query 'Subnets[0].SubnetId' --output text)
priv=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=private \
  --query 'Subnets[0].SubnetId' --output text)
rt=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$priv \
  --query 'RouteTables[0].RouteTableId' --output text)
eip=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
nat=$(aws ec2 create-nat-gateway --subnet-id $pub --allocation-id $eip \
  --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $nat
aws ec2 create-route --route-table-id $rt --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $nat
./path
```

### What it costs

A NAT gateway is billed by the hour and by the gigabyte it processes, and it
lives in one availability zone. A production VPC has one per zone, so that
losing a zone does not cut the others off from the internet, and routes each
private subnet to the one in its own zone. Traffic to S3 or DynamoDB can skip
it entirely through a gateway endpoint, which costs nothing.

</details>
