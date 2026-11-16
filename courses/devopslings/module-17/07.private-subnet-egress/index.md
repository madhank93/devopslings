---
kind: lesson
title: "out to the internet, and no way back in"
description: |
  A batch job in a private subnet has to call a payment API on the internet,
  and must never be reachable from it. Giving it a public address and a
  tight security group is the first idea. Give it a way out that is not a
  way in.
name: private-subnet-egress
slug: private-subnet-egress
createdAt: "2026-11-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      S=/var/lib/devopslings
      for v in $(aws ec2 describe-vpcs --filters Name=tag:lesson,Values=private-subnet-egress --query 'Vpcs[].VpcId' --output text); do
        for n in $(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$v --query 'NatGateways[].NatGatewayId' --output text); do
          aws ec2 delete-nat-gateway --nat-gateway-id $n >/dev/null || true
        done
        for g in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$v --query 'InternetGateways[].InternetGatewayId' --output text); do
          aws ec2 detach-internet-gateway --internet-gateway-id $g --vpc-id $v || true
          aws ec2 delete-internet-gateway --internet-gateway-id $g || true
        done
        for e in $(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$v --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
          aws ec2 delete-network-interface --network-interface-id $e || true
        done
        for r in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$v --query 'RouteTables[].RouteTableId' --output text); do
          for x in $(aws ec2 describe-route-tables --route-table-ids $r --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text); do
            aws ec2 disassociate-route-table --association-id $x || true
          done
          aws ec2 delete-route-table --route-table-id $r 2>/dev/null || true
        done
        for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$v --query 'Subnets[].SubnetId' --output text); do
          aws ec2 delete-subnet --subnet-id $s || true
        done
        aws ec2 delete-vpc --vpc-id $v || true
      done
      for a in $(aws ec2 describe-addresses --query 'Addresses[].AllocationId' --output text); do
        aws ec2 disassociate-address --association-id "$(aws ec2 describe-addresses --allocation-ids $a --query 'Addresses[0].AssociationId' --output text)" 2>/dev/null || true
        aws ec2 release-address --allocation-id $a || true
      done
      rm -rf /root/egress
      install -d /root/egress $S

      cat > $S/private-subnet-egress.path <<'PATHTOOL'
      #!/usr/bin/env python3
      """path: follows traffic between batch-1 and the internet through the route
      tables, gateways and addresses on floci, the way AWS routes it.

        path            both directions: batch-1 -> 203.0.113.10:443, and
                        198.51.100.7 -> batch-1

      floci stores routes and gateways but moves no packets, so this is the
      evaluation AWS would make: longest-prefix match in the subnet's route table
      (its own, or the VPC's main table), and an internet gateway that only
      translates addresses that have a public IP."""
      import ipaddress, json, subprocess, sys

      ENI, OUT, IN = "batch-1", "203.0.113.10", "198.51.100.7"


      def aws(*args):
          return json.loads(subprocess.run(["aws", "ec2", *args, "--output", "json"],
                                           check=True, capture_output=True, text=True).stdout)


      class Net:
          def __init__(self):
              self.eni = next((e for e in aws("describe-network-interfaces")["NetworkInterfaces"]
                               if e.get("Description") == ENI), None)
              if not self.eni:
                  raise SystemExit(f"{ENI} is gone — reset the lesson to get it back")
              self.vpc = self.eni["VpcId"]
              f = ["--filters", f"Name=vpc-id,Values={self.vpc}"]
              self.rts = aws("describe-route-tables", *f)["RouteTables"]
              self.subnets = {s["SubnetId"]: s for s in aws("describe-subnets", *f)["Subnets"]}
              self.nats = {n["NatGatewayId"]: n for n in aws("describe-nat-gateways", "--filter",
                           f"Name=vpc-id,Values={self.vpc}")["NatGateways"]
                           if n.get("State") not in ("deleted", "deleting", "failed")}
              self.igws = {g["InternetGatewayId"] for g in aws("describe-internet-gateways", "--filters",
                           f"Name=attachment.vpc-id,Values={self.vpc}")["InternetGateways"]}

          def name(self, subnet):
              tags = {t["Key"]: t["Value"] for t in self.subnets.get(subnet, {}).get("Tags", [])}
              return f"{tags.get('Name', '?')} subnet ({subnet})"

          def table(self, subnet):
              for rt in self.rts:
                  if any(a.get("SubnetId") == subnet for a in rt.get("Associations", [])):
                      return rt, ""
              main = next(rt for rt in self.rts if any(a.get("Main") for a in rt.get("Associations", [])))
              return main, ", the VPC's main table"

          def route(self, subnet, ip):
              rt, how = self.table(subnet)
              best = None
              for r in rt.get("Routes", []):
                  c = r.get("DestinationCidrBlock")
                  if c and ipaddress.ip_address(ip) in ipaddress.ip_network(c):
                      if best is None or ipaddress.ip_network(c).prefixlen > ipaddress.ip_network(best["DestinationCidrBlock"]).prefixlen:
                          best = r
              target = None
              if best:
                  target = best.get("NatGatewayId") or best.get("GatewayId")
              return rt["RouteTableId"] + how, best and best["DestinationCidrBlock"], target

          def public_ip(self):
              ip = (self.eni.get("Association") or {}).get("PublicIp")
              if ip:
                  return ip
              # floci records an Elastic IP associated with a bare interface without
              # naming the interface; any such address can only be on batch-1.
              nat_enis = {a.get("NetworkInterfaceId") for n in self.nats.values() for a in n.get("NatGatewayAddresses", [])}
              for a in aws("describe-addresses")["Addresses"]:
                  eni = a.get("NetworkInterfaceId")
                  if a.get("AssociationId") and (eni == self.eni["NetworkInterfaceId"] or (not eni and not a.get("InstanceId"))) \
                     and eni not in nat_enis:
                      return a["PublicIp"]
              return None

          def outbound(self):
              """Returns (ok, hops, gateway) for batch-1 -> the internet."""
              hops, subnet, src, seen = [], self.eni["SubnetId"], ENI, set()
              while True:
                  rt, cidr, target = self.route(subnet, OUT)
                  hops.append(f"{src} in the {self.name(subnet)}: route table {rt}")
                  if not target or target == "local":
                      hops.append(f"  no route to {OUT}: dropped")
                      return False, hops, None
                  hops.append(f"  {cidr} -> {target}")
                  if target.startswith("igw-"):
                      if target not in self.igws:
                          hops.append(f"  {target} is not attached to this VPC: dropped")
                          return False, hops, None
                      ip = self.public_ip() if src == ENI else src_ip
                      if not ip:
                          hops.append(f"  an internet gateway only translates addresses that have a public IP;")
                          hops.append(f"  {src} has none: dropped")
                          return False, hops, None
                      hops.append(f"  leaves by {target} as {ip}")
                      return True, hops, target if src == ENI else via
                  if target.startswith("nat-"):
                      nat = self.nats.get(target)
                      if not nat:
                          hops.append(f"  {target} does not exist or is deleted: dropped")
                          return False, hops, None
                      if target in seen:
                          hops.append(f"  the route leads back to {target}: a loop, dropped")
                          return False, hops, None
                      seen.add(target)
                      if nat.get("ConnectivityType") == "private":
                          hops.append(f"  {target} is a private NAT gateway: it has no public address, and its")
                          hops.append(f"  traffic cannot leave by an internet gateway: dropped")
                          return False, hops, None
                      src_ip = next((a.get("PublicIp") for a in nat.get("NatGatewayAddresses", []) if a.get("PublicIp")), None)
                      via, subnet, src = target, nat["SubnetId"], target
                      continue
                  hops.append(f"  {target} does not lead to the internet: dropped")
                  return False, hops, None

          def inbound(self):
              """Returns (reachable, hops) for the internet -> batch-1."""
              ip = self.public_ip()
              if not ip:
                  return False, [f"{IN} -> {ENI}: {ENI} has no public address, so nothing on the internet can address it"]
              rt, cidr, target = self.route(self.eni["SubnetId"], IN)
              if not (target or "").startswith("igw-"):
                  return False, [f"{IN} -> {ip} ({ENI}): the reply has no route back to the internet gateway"]
              return True, [f"{IN} -> {ip}: the internet gateway translates it to {ENI}; only its security",
                            f"group stands between it and the internet"]


      def main():
          n = Net()
          ok, hops, _ = n.outbound()
          print(f"outbound  {ENI} -> {OUT}:443")
          for h in hops:
              print("  " + h)
          print("  " + ("delivered" if ok else "FAILED"))
          reach, hops = n.inbound()
          print(f"inbound   {IN} -> {ENI}")
          for h in hops:
              print("  " + h)
          print("  " + ("REACHABLE" if reach else "not reachable"))


      if __name__ == "__main__":
          main()
      PATHTOOL
      install -m 755 $S/private-subnet-egress.path /root/egress/path

      tag() { aws ec2 create-tags --resources "$1" --tags Key=lesson,Value=private-subnet-egress Key=Name,Value="$2"; }
      v=$(aws ec2 create-vpc --cidr-block 10.30.0.0/16 --query Vpc.VpcId --output text); tag $v billing
      igw=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text); tag $igw billing-igw
      aws ec2 attach-internet-gateway --internet-gateway-id $igw --vpc-id $v
      pub=$(aws ec2 create-subnet --vpc-id $v --cidr-block 10.30.0.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text); tag $pub public
      priv=$(aws ec2 create-subnet --vpc-id $v --cidr-block 10.30.1.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text); tag $priv private
      rt_pub=$(aws ec2 create-route-table --vpc-id $v --query RouteTable.RouteTableId --output text); tag $rt_pub public
      aws ec2 create-route --route-table-id $rt_pub --destination-cidr-block 0.0.0.0/0 --gateway-id $igw >/dev/null
      aws ec2 associate-route-table --route-table-id $rt_pub --subnet-id $pub >/dev/null
      rt_priv=$(aws ec2 create-route-table --vpc-id $v --query RouteTable.RouteTableId --output text); tag $rt_priv private
      aws ec2 associate-route-table --route-table-id $rt_priv --subnet-id $priv >/dev/null
      sg=$(aws ec2 create-security-group --group-name batch --description "batch jobs" --vpc-id $v --query GroupId --output text)
      aws ec2 create-network-interface --subnet-id $priv --groups $sg --private-ip-address 10.30.1.15 --description batch-1 >/dev/null

      cat > /root/egress/README <<'TXT'
      The billing VPC (10.30.0.0/16) has two subnets:

        public   10.30.0.0/24   route table "public":  0.0.0.0/0 -> the internet gateway
        private  10.30.1.0/24   route table "private": nothing but the VPC itself

      batch-1 (10.30.1.15, in the private subnet) runs the nightly settlement
      job. It must call the payment provider's API at 203.0.113.10:443, and it
      cannot: the private subnet has no way out.

        ./path      follows batch-1's traffic out to the internet, and the
                    internet's in to batch-1, as AWS routes it (floci stores
                    routes and gateways but moves no packets)

      Fix it:

        - batch-1 reaches 203.0.113.10:443.
        - Nothing on the internet can reach batch-1, whatever its security
          group says: it has no public address, and the private subnet does
          not give new interfaces one.
        - The private subnet's traffic to the internet leaves by a NAT
          gateway, which leaves by the internet gateway.
      TXT
      echo "scenario ready — /root/egress: ./path, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      S=/var/lib/devopslings
      if [ ! -s $S/private-subnet-egress.path ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      python3 - $S/private-subnet-egress.path <<'PY' || exit 1
      import importlib.machinery, sys
      p = importlib.machinery.SourceFileLoader("path", sys.argv[1]).load_module()
      try:
          n = p.Net()
      except SystemExit as e:
          print(f"not yet: {e}")
          sys.exit(1)

      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      ip = n.public_ip()
      ok, hops, gw = n.outbound()
      if ip:
          reach, _ = n.inbound()
          fail(f"batch-1 has a public address, {ip}. " + ("With the private subnet routed to the internet gateway, anything on the internet can open a connection to it," if reach else "Any route to the internet gateway makes it reachable from the internet,") ,
               "and only its security group decides what gets through: one rule away from exposed.",
               "Release or disassociate the address (aws ec2 disassociate-address), and send",
               "batch-1's traffic out through a NAT gateway instead")
      if n.subnets.get(n.eni["SubnetId"], {}).get("MapPublicIpOnLaunch"):
          fail("the private subnet gives every new interface a public address",
               "(MapPublicIpOnLaunch). The next instance launched there is reachable from the",
               "internet. Turn it off: aws ec2 modify-subnet-attribute --no-map-public-ip-on-launch")
      if not ok:
          last = hops[-1].strip()
          rt, cidr, target = n.route(n.eni["SubnetId"], p.OUT)
          if target and target.startswith("igw-"):
              fail(f"the private subnet routes {cidr} straight to the internet gateway, and",
                   "batch-1 has no public address, so the gateway has nothing to translate it to. Giving it",
                   "one would make it reachable. A NAT gateway in the public subnet translates",
                   "outbound traffic to its own address, and accepts no new inbound connections")
          if target is None or target == "local":
              main = next(r for r in n.rts if any(a.get("Main") for a in r.get("Associations", [])))
              in_main = main["RouteTableId"] not in rt and any(r.get("DestinationCidrBlock") == "0.0.0.0/0" for r in main.get("Routes", []))
              fail(f"batch-1's subnet has no route to the internet: its route table is {rt}.",
                   *(["The VPC's main route table has one, and the private subnet does not use the main",
                      "table: it has its own. Add the route to the table the subnet is associated with"] if in_main else
                     [f"{next(iter(n.nats))} exists; nothing sends traffic to it until the private subnet's",
                      "route table has a route for 0.0.0.0/0 that targets it"] if n.nats else []),
                   "./path shows the lookup")
          if "a loop" in last:
              fail("batch-1's traffic goes to the NAT gateway, and the NAT gateway is in the private",
                   "subnet, whose route for the internet is the NAT gateway itself. A NAT gateway",
                   "needs to sit where the internet gateway is the next hop: the public subnet")
          print("not yet: batch-1 cannot reach 203.0.113.10. ./path:")
          for h in hops:
              print("           " + h)
          sys.exit(1)
      if not (gw or "").startswith("nat-"):
          fail(f"batch-1 reaches the internet by {gw}, not by a NAT gateway")
      PY
      echo "PASS — batch-1 reaches the payment API through a NAT gateway in the public subnet,"
      echo "       has no public address, and the private subnet hands out none."
---
