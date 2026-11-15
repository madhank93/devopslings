---
title: "five teams ask which tool, and one answer is neither"
---

## The situation

Five teams want infrastructure as code, and each has already picked a
favourite. Their cases are in `/root/decisions/cases`:

1. a platform team whose changes are reviewed by people who read HCL plans
2. a signup service that must create a customer's environment forty times a
   day, and know whether it worked
3. two hundred long-lived VMs that need one line of `nginx.conf` changed
4. a network team with a tested Go package that allocates subnets
5. a compliance rule about open source and where state may live

Most arguments about Pulumi and OpenTofu are about the language: a compiler,
loops, tests. Those are real, and they almost never decide anything. Both
tools can test. Both use mostly the same providers. Both are open source. The
choice usually turns on one fact about the people, the program around the
tool, or the job itself. Sometimes that fact says neither tool fits.

## Your objectives

For each case, write a line in `answers.txt`:

```
case-N: tool=<pulumi|opentofu|either|neither> because=<token>
```

The `because=` tokens are listed in the file. Pick the constraint that
decides the case: the one that would still decide it if everything else in
the case changed.

## What you're being graded on

Each case must have the right tool and the right reason, from the listed
values. A wrong tool gets a question to reread the case with. A right tool
with the wrong reason gets an explanation of why that reason does not
separate the two tools.

<details>
<summary>Hint 1 — the questions to ask</summary>

- Who has to read every change before it ships, and what can they read?
- What starts the change: a person at a terminal, or another program?
- Is anything being created or replaced, or does software on machines that
  already exist have to change?
- If the same rules live in two places, what happens the next time they
  change?
- Is the objection about the tool, or about one way of running it?

</details>

<details>
<summary>Hint 2 — the reasons that rarely decide</summary>

`compiler`, `testing`, `providers` and `licence` are in the list because
people reach for them first. Check each against both tools:

- OpenTofu has `tofu validate` and typed variables. Pulumi has a compiler.
- OpenTofu has `tofu test` with mock providers. Pulumi has `WithMocks`.
- Pulumi can use any Terraform provider, and most of its own are built from
  them.
- OpenTofu is MPL-2.0. The Pulumi CLI is Apache-2.0.

</details>

<details>
<summary>Hint 3 — case 5</summary>

Every stack in this module keeps its state at a `file://` URL, and Pulumi
Cloud has not been involved once. `pulumi login s3://bucket` is the same idea
with object storage. Look at what the rule asks for, and whether either tool
fails it.

</details>

<details>
<summary>Solution</summary>

```
case-1: tool=opentofu because=readers
case-2: tool=pulumi   because=embedding
case-3: tool=neither  because=mutation
case-4: tool=pulumi   because=reuse
case-5: tool=either   because=backend
```

1. **readers.** The plan and the diff are the review. The four people who do
   it read HCL. Rewrite the modules in Go, and every change goes through
   reviewers who cannot read it, to get a compiler that `tofu validate`
   mostly already gives them.
2. **embedding.** The trigger is a program, not a person. Pulumi's
   Automation API runs a stack from inside a Go service, and returns a Go
   error or a result. Driving `tofu` from a service means shelling out and
   parsing its output.
3. **mutation.** Nothing is being created. The VMs stay, and a file on them
   must change, with a reload. That is configuration management: Ansible,
   module 15. Either IaC tool would want to replace the VMs to change them.
4. **reuse.** The allocation rules already exist as a tested Go package. A
   Pulumi program imports it, so there is one copy of the rules. An HCL port
   is the second copy that already caused an outage.
5. **backend.** Both tools are open source and self-hostable, and both can
   keep state in the company's own object storage. The manager's premise is
   wrong. Pulumi Cloud is the default, not a requirement, so the team need
   not move.

### What the module was about

The language is the least of the difference. What Pulumi changes is the
program around the infrastructure. It can be imported, tested, embedded in
a service, and written by people who write Go. When nobody on the team does,
or nobody needs any of that, it is a cost with nothing to show for it. When
the job is not creating infrastructure at all, neither tool is the answer.

</details>
