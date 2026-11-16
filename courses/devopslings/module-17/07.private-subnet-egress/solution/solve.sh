#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
pub=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=public --query 'Subnets[0].SubnetId' --output text)
priv=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=private --query 'Subnets[0].SubnetId' --output text)
rt=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$priv --query 'RouteTables[0].RouteTableId' --output text)
eip=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
nat=$(aws ec2 create-nat-gateway --subnet-id $pub --allocation-id $eip --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $nat
aws ec2 create-route --route-table-id $rt --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $nat
/root/egress/path
