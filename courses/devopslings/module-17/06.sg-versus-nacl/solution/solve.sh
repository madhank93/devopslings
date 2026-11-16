#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/orders
db=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=db --query 'Subnets[0].SubnetId' --output text)
acl=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=$db --query 'NetworkAcls[0].NetworkAclId' --output text)
# The reply leaves 5432 and goes back to the client's ephemeral port.
aws ec2 replace-network-acl-entry --network-acl-id $acl --egress --rule-number 100 --protocol 6 \
  --port-range From=1024,To=65535 --cidr-block 10.20.1.0/24 --rule-action allow
sed -i -e 's/^dropped_by=.*/dropped_by=network-acl/' -e 's/^packet=.*/packet=reply/' \
  -e 's/^because=.*/because=stateful/' -e 's/^to_port=.*/to_port=ephemeral/' ANSWER
./reach
