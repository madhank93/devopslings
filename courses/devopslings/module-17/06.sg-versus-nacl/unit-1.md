---
title: "the security group allows it and the traffic still dies"
---

## The situation

The orders VPC (`10.20.0.0/16`) has an app subnet (`10.20.1.0/24`) and a db
subnet (`10.20.2.0/24`). `app-1` (`10.20.1.10`) cannot connect to Postgres on
`db-1` (`10.20.2.20:5432`). The db security group allows 5432 from the app
security group, so the first idea is to widen it: any port, then any source.
The connection still fails.

AWS filters traffic in two places. A **security group** is attached to a
network interface. A **network ACL** is attached to a subnet. They behave
differently:

| | security group | network ACL |
|---|---|---|
| attached to | an interface | a subnet |
| rules | allow only | allow and deny, numbered, first match wins |
| state | stateful | stateless |

floci stores both kinds of rule but moves no packets. `/root/orders/reach`
follows one connection through every rule the way AWS evaluates them, and
prints where it dies.

Find a subnet's NACL by its association
(`--filters Name=association.subnet-id,Values=<subnet-id>`): floci ignores
tag filters on `describe-network-acls` and returns every NACL.

## Your objectives

1. `app-1` reaches `db-1:5432` from any client port that Linux, Windows or a
   load balancer would use.
2. The db subnet's NACL still refuses everything else: other ports from the
   app subnet, anything from outside the VPC, and traffic leaving the subnet
   that is not a reply to the app subnet.
3. The db security group allows what it allowed before, and no more.
4. Fill in `/root/orders/ANSWER`.

## What you're being graded on

The grader follows the connection from client ports 1024, 32768, 49152,
60999 and 65535, and every one must arrive and get its reply back. It then
checks that the db subnet's NACL refuses SSH from the app subnet, Postgres
from outside the VPC, HTTPS out to the internet, and a new connection out to
the app subnet's SSH port. The db security group must hold only 5432 from the
app security group. `ANSWER` must name the rule that dropped the traffic, the
packet it dropped, the port that packet was addressed to, and why the other
kind of rule let it through.

<details>
<summary>Hint 1 — which packet dies</summary>

Run `./reach`. A TCP connection is two flows: the request to 5432, and the
reply from 5432 back to the client. Read which one stops, and at which rule.

</details>

<details>
<summary>Hint 2 — where the reply goes</summary>

The reply comes *from* 5432. It goes *to* the port the client sent from,
which the client's operating system picked from its ephemeral range. Try
`./reach app-1 db-1 5432 40000`. The NACL's outbound rule was written as a
mirror of the inbound one.

</details>

<details>
<summary>Hint 3 — the range</summary>

Linux picks from 32768-60999, Windows from 49152-65535, and an AWS load
balancer from 1024-65535. Allow the reply to the app subnet's CIDR on the
widest of these, and nowhere else.

</details>

<details>
<summary>Solution</summary>

```
db=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=db \
  --query 'Subnets[0].SubnetId' --output text)
acl=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=$db \
  --query 'NetworkAcls[0].NetworkAclId' --output text)
aws ec2 replace-network-acl-entry --network-acl-id $acl --egress --rule-number 100 \
  --protocol 6 --port-range From=1024,To=65535 --cidr-block 10.20.1.0/24 --rule-action allow
```

```
dropped_by=network-acl
packet=reply
because=stateful
to_port=ephemeral
```

### Why the security group needed no rule

A security group is stateful: it tracks connections, and the reply to a
request it allowed is let back out without any outbound rule. A NACL is
stateless: it judges each packet on its own, so the reply needs a rule of its
own, on the ports the reply is sent *to*. Widening the security group could
never help, because the security group never dropped anything.

</details>
