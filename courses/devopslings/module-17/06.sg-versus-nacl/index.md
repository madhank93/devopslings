---
kind: lesson
title: "the security group allows it and the traffic still dies"
description: |
  The app subnet cannot reach Postgres in the db subnet. The security group
  allows port 5432, so the first fix is to widen it. The packet that dies is
  the reply, and the rule that drops it is not in a security group.
name: sg-versus-nacl
slug: sg-versus-nacl
createdAt: "2026-11-14"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      S=/var/lib/devopslings
      for v in $(aws ec2 describe-vpcs --filters Name=tag:lesson,Values=sg-versus-nacl --query 'Vpcs[].VpcId' --output text); do
        for e in $(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$v --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
          aws ec2 delete-network-interface --network-interface-id $e || true
        done
        for a in $(aws ec2 describe-network-acls --filters Name=vpc-id,Values=$v --query 'NetworkAcls[?!IsDefault].NetworkAclId' --output text); do
          for x in $(aws ec2 describe-network-acls --network-acl-ids $a --query 'NetworkAcls[0].Associations[].NetworkAclAssociationId' --output text); do
            d=$(aws ec2 describe-network-acls --filters Name=vpc-id,Values=$v Name=default,Values=true --query 'NetworkAcls[0].NetworkAclId' --output text)
            aws ec2 replace-network-acl-association --association-id $x --network-acl-id $d >/dev/null || true
          done
          aws ec2 delete-network-acl --network-acl-id $a || true
        done
        for g in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$v --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
          aws ec2 delete-security-group --group-id $g || true
        done
        for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$v --query 'Subnets[].SubnetId' --output text); do
          aws ec2 delete-subnet --subnet-id $s || true
        done
        aws ec2 delete-vpc --vpc-id $v || true
      done
      rm -rf /root/orders
      install -d /root/orders $S

      cat > $S/sg-versus-nacl.reach <<'REACH'
      #!/usr/bin/env python3
      """reach: follows one TCP connection between two network interfaces through
      the security groups and network ACLs on floci, the way AWS evaluates them.

        reach [SRC DST PORT [SRC_PORT]]   names are ENI descriptions; default app-1 db-1 5432

      floci stores these rules but moves no packets, so this is the evaluation AWS
      would make: NACLs per subnet, stateless, lowest rule number first; security
      groups per interface, stateful, any matching rule allows."""
      import ipaddress, json, subprocess, sys


      def aws(*args):
          return json.loads(subprocess.run(["aws", "ec2", *args, "--output", "json"],
                                           check=True, capture_output=True, text=True).stdout)


      def in_cidr(ip, cidr):
          return ipaddress.ip_address(ip) in ipaddress.ip_network(cidr, strict=False)


      def proto_ok(rule_proto, port, rng):
          if str(rule_proto) == "-1":
              return True
          if str(rule_proto) not in ("6", "tcp"):
              return False
          if not rng:
              return True
          return rng.get("From", rng.get("FromPort", 0)) <= port <= rng.get("To", rng.get("ToPort", 65535))


      def nacl_for(subnet, acls):
          for a in acls:
              if any(x.get("SubnetId") == subnet for x in a.get("Associations", [])):
                  return a
          return next(a for a in acls if a.get("IsDefault"))


      def nacl_eval(acl, egress, peer_ip, port):
          for e in sorted((e for e in acl["Entries"] if e["Egress"] == egress), key=lambda e: e["RuleNumber"]):
              if not e.get("CidrBlock") or not in_cidr(peer_ip, e["CidrBlock"]):
                  continue
              if not proto_ok(e["Protocol"], port, e.get("PortRange")):
                  continue
              n = "*" if e["RuleNumber"] == 32767 else e["RuleNumber"]
              return e["RuleAction"] == "allow", f"rule {n}"
          return False, "no rule matched"


      def sg_eval(groups, sgs, egress, peer_ip, peer_groups, port):
          for g in groups:
              sg = sgs[g]
              for p in sg["IpPermissionsEgress" if egress else "IpPermissions"]:
                  if not proto_ok(p["IpProtocol"], port, p if "FromPort" in p else None):
                      continue
                  if any(in_cidr(peer_ip, r["CidrIp"]) for r in p.get("IpRanges", [])) or \
                     any(u["GroupId"] in peer_groups for u in p.get("UserIdGroupPairs", [])):
                      return True, sg["GroupName"]
          return False, "no rule matched"


      def main():
          src_name, dst_name, port = (sys.argv[1:4] + ["app-1", "db-1", "5432"][len(sys.argv[1:4]):])
          port = int(port)
          sport = int(sys.argv[4]) if len(sys.argv) > 4 else 49152
          enis = {e.get("Description"): e for e in aws("describe-network-interfaces")["NetworkInterfaces"]}
          src, dst = enis[src_name], enis[dst_name]
          acls = aws("describe-network-acls", "--filters", f"Name=vpc-id,Values={src['VpcId']}")["NetworkAcls"]
          sgs = {g["GroupId"]: g for g in aws("describe-security-groups", "--filters", f"Name=vpc-id,Values={src['VpcId']}")["SecurityGroups"]}
          s_ip, d_ip = src["PrivateIpAddress"], dst["PrivateIpAddress"]
          s_grp = [g["GroupId"] for g in src["Groups"]]
          d_grp = [g["GroupId"] for g in dst["Groups"]]
          s_acl, d_acl = nacl_for(src["SubnetId"], acls), nacl_for(dst["SubnetId"], acls)

          hops = [
              ("request", f"{src_name} security group, outbound", sg_eval(s_grp, sgs, True, d_ip, d_grp, port)),
              ("request", f"{src_name} subnet NACL {s_acl['NetworkAclId']}, outbound", nacl_eval(s_acl, True, d_ip, port)),
              ("request", f"{dst_name} subnet NACL {d_acl['NetworkAclId']}, inbound", nacl_eval(d_acl, False, s_ip, port)),
              ("request", f"{dst_name} security group, inbound", sg_eval(d_grp, sgs, False, s_ip, s_grp, port)),
              ("reply", f"{dst_name} security group", (True, "stateful: a reply to an allowed request")),
              ("reply", f"{dst_name} subnet NACL {d_acl['NetworkAclId']}, outbound", nacl_eval(d_acl, True, s_ip, sport)),
              ("reply", f"{src_name} subnet NACL {s_acl['NetworkAclId']}, inbound", nacl_eval(s_acl, False, d_ip, sport)),
              ("reply", f"{src_name} security group", (True, "stateful: a reply to an allowed request")),
          ]
          heads = {"request": f"request  {s_ip}:{sport} -> {d_ip}:{port}",
                   "reply": f"reply    {d_ip}:{port} -> {s_ip}:{sport}"}
          shown = set()
          for leg, where, (ok, why) in hops:
              if leg not in shown:
                  print(heads[leg])
                  shown.add(leg)
              print(f"  {where:<52} {'allow' if ok else 'DENY '}  ({why})")
              if not ok:
                  print(f"dropped: {leg} at {where}")
                  sys.exit(1)
          print("delivered")


      if __name__ == "__main__":
          main()
      REACH
      install -m 755 $S/sg-versus-nacl.reach /root/orders/reach

      tag() { aws ec2 create-tags --resources "$1" --tags Key=lesson,Value=sg-versus-nacl Key=Name,Value="$2"; }
      v=$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 --query Vpc.VpcId --output text); tag $v orders
      app=$(aws ec2 create-subnet --vpc-id $v --cidr-block 10.20.1.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text); tag $app app
      db=$(aws ec2 create-subnet --vpc-id $v --cidr-block 10.20.2.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text); tag $db db
      sg_app=$(aws ec2 create-security-group --group-name app --description "app servers" --vpc-id $v --query GroupId --output text)
      sg_db=$(aws ec2 create-security-group --group-name db --description "postgres" --vpc-id $v --query GroupId --output text)
      aws ec2 authorize-security-group-ingress --group-id $sg_db \
        --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$sg_app}]" >/dev/null
      aws ec2 create-network-interface --subnet-id $app --groups $sg_app --private-ip-address 10.20.1.10 --description app-1 >/dev/null
      aws ec2 create-network-interface --subnet-id $db --groups $sg_db --private-ip-address 10.20.2.20 --description db-1 >/dev/null

      # The db subnet's NACL: someone mirrored the inbound rule for the
      # outbound direction.
      acl=$(aws ec2 create-network-acl --vpc-id $v --query NetworkAcl.NetworkAclId --output text); tag $acl db-acl
      aws ec2 create-network-acl-entry --network-acl-id $acl --ingress --rule-number 100 --protocol 6 \
        --port-range From=5432,To=5432 --cidr-block 10.20.1.0/24 --rule-action allow
      aws ec2 create-network-acl-entry --network-acl-id $acl --egress --rule-number 100 --protocol 6 \
        --port-range From=5432,To=5432 --cidr-block 10.20.1.0/24 --rule-action allow
      assoc=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=$db \
        --query "NetworkAcls[0].Associations[?SubnetId=='$db'].NetworkAclAssociationId" --output text)
      aws ec2 replace-network-acl-association --association-id $assoc --network-acl-id $acl >/dev/null

      cd /root/orders
      cat > ANSWER <<'TXT'
      # Replace each ? with one of the listed words.
      #
      # Which kind of rule dropped the traffic?   security-group | network-acl | route-table
      dropped_by=?
      # Which packet did it drop?                  request | reply
      packet=?
      # Why did the other kind of rule let that packet through without a rule of its own?
      #                                            stateless | stateful | rule-order | default-deny
      because=?
      # Which port is the dropped packet addressed to?   5432 | ephemeral
      to_port=?
      TXT

      cat > README <<'TXT'
      The orders VPC (10.20.0.0/16) has an app subnet (10.20.1.0/24) and a db
      subnet (10.20.2.0/24). app-1 (10.20.1.10) cannot connect to Postgres on
      db-1 (10.20.2.20:5432), although the db security group allows 5432 from
      the app security group.

        ./reach     follows the connection through every rule, as AWS evaluates
                    them (floci stores network rules but moves no packets)

      Fix it:

        - app-1 reaches db-1:5432, from any client port a Linux, Windows or
          load-balancer client would use.
        - The db subnet's NACL still refuses everything else: other ports from
          the app subnet, anything from outside the VPC, and traffic out of
          the subnet that is not a reply to the app subnet.
        - The db security group allows what it allowed before, and no more.
        - Fill in ANSWER.

      Find a subnet's NACL by its association: floci ignores tag filters on
      describe-network-acls and returns every NACL.

        aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=<subnet-id>
      TXT
      echo "scenario ready — /root/orders: ./reach, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      if ! cd /root/orders 2>/dev/null; then
        echo "not yet: /root/orders is gone — reset the lesson to get it back"
        exit 1
      fi
      S=/var/lib/devopslings
      if [ ! -s $S/sg-versus-nacl.reach ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      if [ ! -f ANSWER ]; then
        echo "not yet: /root/orders/ANSWER is missing — reset the lesson to get the template back"
        exit 1
      fi
      tok() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([A-Za-z0-9?-]*\).*/\1/p" ANSWER | head -1 | tr 'A-Z' 'a-z'; }
      dropped_by=$(tok dropped_by); packet=$(tok packet); because=$(tok because); to_port=$(tok to_port)
      chk() { local v=$1 name=$2; shift 2; for o in "$@"; do [ "$v" = "$o" ] && return 0; done
        echo "not yet: ANSWER needs $name= one of: $*"; exit 1; }
      chk "$dropped_by" dropped_by security-group network-acl route-table
      chk "$packet" packet request reply
      chk "$because" because stateless stateful rule-order default-deny
      chk "$to_port" to_port 5432 ephemeral

      if ! python3 - $S/sg-versus-nacl.reach <<'PY'
      import importlib.machinery, sys
      r = importlib.machinery.SourceFileLoader("reach", sys.argv[1]).load_module()
      enis = {e.get("Description"): e for e in r.aws("describe-network-interfaces")["NetworkInterfaces"]}
      if "app-1" not in enis or "db-1" not in enis:
          print("not yet: app-1 or db-1 is gone — reset the lesson to get them back")
          sys.exit(1)
      app, db = enis["app-1"], enis["db-1"]
      vpc = app["VpcId"]
      acls = r.aws("describe-network-acls", "--filters", f"Name=vpc-id,Values={vpc}")["NetworkAcls"]
      sgs = {g["GroupId"]: g for g in r.aws("describe-security-groups", "--filters", f"Name=vpc-id,Values={vpc}")["SecurityGroups"]}
      app_acl, db_acl = r.nacl_for(app["SubnetId"], acls), r.nacl_for(db["SubnetId"], acls)
      app_grp = [g["GroupId"] for g in app["Groups"]]
      db_grp = [g["GroupId"] for g in db["Groups"]]
      A, D = app["PrivateIpAddress"], db["PrivateIpAddress"]

      # The connection, from the client ports real clients use: Linux
      # 32768-60999, Windows 49152-65535, load balancers 1024-65535.
      for sport in (1024, 32768, 49152, 60999, 65535):
          legs = [
              ("the request", "app-1's security group, outbound", r.sg_eval(app_grp, sgs, True, D, db_grp, 5432)),
              ("the request", "the app subnet's NACL, outbound", r.nacl_eval(app_acl, True, D, 5432)),
              ("the request", "the db subnet's NACL, inbound", r.nacl_eval(db_acl, False, A, 5432)),
              ("the request", "db-1's security group, inbound", r.sg_eval(db_grp, sgs, False, A, app_grp, 5432)),
              (f"the reply to port {sport}", "the db subnet's NACL, outbound", r.nacl_eval(db_acl, True, A, sport)),
              (f"the reply to port {sport}", "the app subnet's NACL, inbound", r.nacl_eval(app_acl, False, D, sport)),
          ]
          for what, where, (ok, why) in legs:
              if not ok:
                  print(f"not yet: app-1 cannot reach db-1:5432 from client port {sport}: {what} is")
                  print(f"         dropped at {where} ({why}). ./reach {'app-1 db-1 5432 ' + str(sport)} shows the path")
                  if "reply" in what and sport != 49152:
                      print("         Clients pick their port from an ephemeral range that depends on the OS:")
                      print("         Linux 32768-60999, Windows 49152-65535, load balancers 1024-65535")
                  sys.exit(1)

      # What the db subnet's NACL must still refuse.
      for desc, egress, ip, port in (
          ("SSH (22) into the db subnet from the app subnet", False, A, 22),
          ("Postgres (5432) into the db subnet from outside the VPC", False, "198.51.100.7", 5432),
          ("HTTPS (443) out of the db subnet to the internet", True, "198.51.100.7", 443),
          ("traffic out of the db subnet to the internet on high ports", True, "198.51.100.7", 40000),
          ("a connection out of the db subnet to the app subnet's SSH port", True, A, 22),
      ):
          ok, why = r.nacl_eval(db_acl, egress, ip, port)
          if ok:
              print(f"not yet: Postgres is reachable, and the db subnet's NACL now also allows {desc}")
              print(f"         ({why}). The reply only needs the ephemeral ports, to the app subnet")
              sys.exit(1)

      # The db security group: 5432 from the app group, as before, nothing more.
      for p in sgs[db_grp[0]]["IpPermissions"]:
          ports = (p.get("FromPort"), p.get("ToPort"))
          wide = p["IpProtocol"] == "-1" or ports != (5432, 5432)
          cidrs = [x["CidrIp"] for x in p.get("IpRanges", [])]
          if wide or cidrs:
              print("not yet: the db security group was widened:", p["IpProtocol"], ports, cidrs or "")
              print("         It was never the problem; a security group is stateful, so the reply to")
              print("         an allowed request is always let back out. Put it back the way it was:")
              print("         5432 from the app security group only")
              sys.exit(1)
      PY
      then
        exit 1
      fi

      if [ "$dropped_by" != network-acl ] || [ "$packet" != reply ]; then
        echo "not yet: the connection works. ANSWER says the $packet was dropped by a $dropped_by;"
        echo "         ./reach on a fresh reset shows which packet died, and where"
        exit 1
      fi
      if [ "$to_port" != ephemeral ]; then
        echo "not yet: the connection works. ANSWER says the reply is addressed to port 5432."
        echo "         5432 is where the reply comes from. It goes back to the port the client"
        echo "         sent from, which the client's OS picked from its ephemeral range"
        exit 1
      fi
      if [ "$because" != stateful ]; then
        case "$because" in
          stateless) echo "not yet: the connection works. ANSWER says the security group let the reply"
                     echo "         through because it is stateless. Which of the two remembers the"
                     echo "         connection, and which judges every packet on its own?" ;;
          default-deny) echo "not yet: the rule that matched the reply was the NACL's final deny, true. The"
                        echo "         question is why the security group needed no rule at all for it" ;;
          *) echo "not yet: the connection works. Rule order decides which NACL rule matches, not"
             echo "         why the security group needed no rule for the reply" ;;
        esac
        exit 1
      fi
      echo "PASS — app-1 reaches db-1:5432 from every client port range, the db subnet's"
      echo "       NACL still refuses everything else, and the security group is unchanged."
---
