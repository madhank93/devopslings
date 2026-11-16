---
kind: lesson
title: "five teams ask which tool, and one answer is neither"
description: |
  Five teams want infrastructure as code. Some should use Pulumi, some
  OpenTofu, one either, and one neither. Pick a tool for each and name the
  single constraint that decides it.
name: when-not-to
slug: when-not-to
createdAt: "2026-11-13"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 60
    run: |
      rm -rf /root/decisions
      install -d /root/decisions/cases
      cd /root/decisions

      cat > cases/case-1-platform.md <<'CASE'
      # Case 1 — the platform team

      Four operations engineers own the shared networks, DNS and databases.
      Every change is reviewed in a pull request by two of them, and the review
      is done by reading the plan and the diff. None of them writes Go, Python
      or TypeScript, and hiring for it is not planned. They maintain sixty HCL
      modules that work.

      A developer on another team proposes rewriting the modules in Go "so we
      get a compiler".
      CASE

      cat > cases/case-2-signup.md <<'CASE'
      # Case 2 — per-customer environments

      When a customer signs up, the signup service must create that customer's
      isolated database, bucket and DNS record, and tear them down when the
      account closes. It happens about forty times a day, at any hour. No human
      runs a CLI, and the signup service must know whether the create
      succeeded before it emails the customer.
      CASE

      cat > cases/case-3-fleet.md <<'CASE'
      # Case 3 — the nginx fleet

      Two hundred long-lived VMs run nginx. They are not being replaced. A
      security fix means a TLS setting in nginx.conf must change on every one
      of them and nginx must be reloaded, without restarting the VMs and
      without dropping connections.
      CASE

      cat > cases/case-4-subnets.md <<'CASE'
      # Case 4 — the address plan

      The network team owns a Go package that allocates subnets per region and
      per environment. It has years of edge cases and a thorough test suite,
      and the IPAM service is built on it. The infrastructure for each new
      region must use exactly the same allocation. Two implementations of the
      rules, one in Go and one in HCL, have drifted apart before, and caused an
      outage.
      CASE

      cat > cases/case-5-compliance.md <<'CASE'
      # Case 5 — the compliance rule

      A new rule: every tool in the deploy path must be open source and
      self-hostable, and infrastructure state must be stored only in the
      company's own object storage. Legal has already checked both tools'
      licences and is happy with them.

      The applications team already uses Pulumi. A manager says they have to
      move to OpenTofu, "because Pulumi keeps its state in Pulumi Cloud".
      CASE

      cat > answers.txt <<'ANS'
      # One line per case. Replace every ? with your answer.
      #
      #   tool=     pulumi | opentofu | either | neither
      #   because=  readers | embedding | mutation | reuse | backend
      #             | compiler | testing | providers | licence
      #
      # Name the constraint that decides it: the one that would still decide it
      # if everything else in the case changed.

      case-1: tool=? because=?
      case-2: tool=? because=?
      case-3: tool=? because=?
      case-4: tool=? because=?
      case-5: tool=? because=?
      ANS

      cat > README <<'TXT'
      Five teams want infrastructure as code. The cases are in cases/.

      For each case, pick the tool and name the constraint that decided it.
      Write it in answers.txt, which lists the allowed values.

      Nothing needs to be installed or run. You are graded on the choices and
      the reasons.
      TXT
      echo "scenario ready — five cases in /root/decisions/cases, answers in /root/decisions/answers.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      ans=/root/decisions/answers.txt
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty — reset the lesson to get the template back"
        exit 1
      fi

      fail=0
      for row in "1 opentofu readers" "2 pulumi embedding" "3 neither mutation" "4 pulumi reuse" "5 either backend"; do
        set -- $row
        n=$1 want_tool=$2 want_why=$3
        line=$(grep -E "^case-$n:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: no 'case-$n:' line in $ans"
          exit 1
        fi
        tool=$(printf '%s' "$line" | sed -n 's/.*tool=\([A-Za-z?]*\).*/\1/p' | tr 'A-Z' 'a-z')
        why=$(printf '%s' "$line" | sed -n 's/.*because=\([A-Za-z?]*\).*/\1/p' | tr 'A-Z' 'a-z')
        case "$tool" in
          pulumi|opentofu|either|neither) ;;
          ""|"?") echo "not yet: case-$n has no tool — it must be pulumi, opentofu, either or neither"; exit 1 ;;
          *) echo "not yet: case-$n says tool=$tool, which is not one of pulumi, opentofu, either, neither"; exit 1 ;;
        esac
        case "$why" in
          readers|embedding|mutation|reuse|backend|compiler|testing|providers|licence) ;;
          ""|"?") echo "not yet: case-$n has no because= token"; exit 1 ;;
          *) echo "not yet: case-$n says because=$why, which is not one of the listed tokens"; exit 1 ;;
        esac

        if [ "$tool" != "$want_tool" ]; then
          fail=1
          echo "not yet: case-$n — you picked $tool."
          case "$n" in
            1) echo "         Ask who has to read every change before it ships, and what they can read." ;;
            2) echo "         Ask what has to start the change, and what has to learn whether it worked." ;;
            3) echo "         Both tools create and replace infrastructure. Ask whether anything here is"
               echo "         being created, or whether software on machines that already exist must change." ;;
            4) echo "         Ask what happens the next time the allocation rules change, if there are"
               echo "         two copies of them." ;;
            5) echo "         Ask where Pulumi can keep its state. 'pulumi login' accepts more than one"
               echo "         kind of URL: this module's stacks use file://, and s3:// works too." ;;
          esac
          continue
        fi
        if [ "$why" != "$want_why" ]; then
          fail=1
          echo "not yet: case-$n — $tool is right, and '$why' is not what decides it."
          case "$why" in
            compiler) echo "         A compiler checks types. In this case, would it change the decision if the" 
                      echo "         other tool had one too?" ;;
            testing)  echo "         OpenTofu has 'tofu test' with mock providers, and Pulumi has mocks. Both can"
                      echo "         test, so testing cannot be what separates them here." ;;
            providers) echo "         Pulumi can use any Terraform provider, and most of its own providers are"
                       echo "         built from them. Provider coverage rarely separates the two." ;;
            licence)  echo "         The OpenTofu CLI is MPL-2.0 and the Pulumi CLI is Apache-2.0. Both are open"
                      echo "         source, so the licence cannot decide between them." ;;
            *)        echo "         Reread the case for the one fact that would still decide it if everything"
                      echo "         else changed." ;;
          esac
        fi
      done
      if [ "$fail" = 1 ]; then
        exit 1
      fi
      echo "PASS — each case has the tool its constraint calls for, and the constraint named."
---
