# devopslings

Learn DevOps by fixing things that are already broken, on your own machine,
with a check that can tell whether you actually fixed it.

Every lesson is a small system in a genuinely broken state. You get a terminal
and an objective. When you think you're done, an automated check either agrees
or tells you specifically what is still wrong.

```
$ devopslings start disk-full-triage
scenario ready — /var/log/app is at 91%

$ devopslings verify disk-full-triage
not yet: log-exporter.service is running again — did you kill the process
         instead of stopping the unit?
```

Nothing here needs a cloud account, a credit card, or an internet connection
after the first run. Everything is open source and runs in Docker.

---

## Why another DevOps course

Most of them teach you to *deploy* things. Almost none of them make you prove a
system survives when something goes wrong — which is the actual job.

So the centre of gravity here is the back half of the curriculum: percentiles
and tail latency, retry storms and circuit breakers, split-brain and failover,
restore drills that actually restore, error budgets, DORA. It turns out that
material is also the most mechanically checkable content in the whole subject:

- **High availability** — the check kills the primary and asserts the service
  still answers. You cannot fake having survived.
- **Disaster recovery** — the check restores your backup into a *fresh, empty*
  container and looks for a known row. A backup that cannot restore fails.
- **Resilience** — the check injects 8 seconds of latency into a dependency and
  asserts you still serve customers.
- **Performance** — k6's `thresholds` exit non-zero on breach, so the load test
  *is* the grade.

## Quick start

```bash
git clone https://github.com/madhank93/devopslings
cd devopslings
mise run setup                     # or: go build -o bin/devopslings ./cmd/devopslings
./bin/devopslings                  # the TUI
./bin/devopslings doctor           # check Docker, memory, ports
```

Requires Docker (or Podman) with at least 4 GiB allocated, and Go 1.25+.
[mise](https://mise.jdx.dev) pins everything else.

### Working a lesson

Run `devopslings` with no arguments for the TUI: lessons on the left, the
lesson's prose on the right, and task output streaming underneath as it happens
— a first `start` pulls images for a few minutes, and you should be able to
watch it rather than wonder.

```
↵ play · i start · v verify · r reset · t shell · h hint · s solution · d down · / find · n next · ? help · q quit
```

The keys match [kubelings](https://github.com/madhank93/kubelings) and
[golings](https://github.com/madhank93/golings), so the muscle memory carries
between the three courses. `↵` plays a lesson: sandbox up, scenario broken,
shell open. `s` asks before revealing a solution, and `d` asks before dropping
a sandbox's volumes. Starting a lesson while another lesson on the *same*
sandbox is in progress also asks — `init_scenario` resets that sandbox, and the
other lesson's work goes with it.

The shell you land in has the lesson wired into it — `task`, `hint`,
`solution`, `verify` and `reset` are commands, so you can grade yourself
without leaving the box. On a host-side lesson `verify` records the pass; inside
a container it runs the same check but cannot record it, so press `v` when you
get back.

`/` filters, `n` jumps to the next unsolved lesson, `tab` moves focus and
`j/k`, `pgup/pgdn`, `G` scroll whichever pane has it. `esc` cancels a running
task. `?` lists the lot.

Every key has a subcommand behind it, which is what CI and scripts use:

```bash
devopslings show   <lesson>   # what you're being asked to do
devopslings start  <lesson>   # bring up the sandbox and break it
devopslings shell  <lesson>   # get a terminal inside it
devopslings verify <lesson>   # grade it
devopslings reset  <lesson>   # start over from scratch
devopslings down   <lesson>   # stop the sandbox
```

Hints and a full walkthrough live in each lesson's `unit-1.md`, behind
collapsed `<details>` blocks. Use them — they explain *why*, which is the part
that transfers.

## What it covers

Twenty-one modules from Linux triage to DORA. See
[CURRICULUM.md](CURRICULUM.md) for the full map.

Three areas are deliberately **not** covered here, because they have their own
repos:

| Topic | Go to |
|---|---|
| Kubernetes, GitOps, service mesh | [kubelings](https://github.com/madhank93/kubelings) |
| Go itself | [golings](https://github.com/madhank93/golings) |
| Kubernetes security (CKS) | [learn-cks](https://github.com/madhank93/learn-cks) |

## Tooling choices

The curriculum follows the [roadmap.sh DevOps track](https://roadmap.sh/devops),
with one rule applied on top: **where the recommended tool isn't open source,
the open source one wins.** Several of the roadmap's picks have relicensed since
it was drawn.

| Roadmap says | We use | Why |
|---|---|---|
| Terraform | **OpenTofu** | Terraform moved to BUSL-1.1 in 2023 |
| Vault | **OpenBao** | Vault moved to BUSL |
| AWS | **floci** | Local AWS emulator, MIT. LocalStack archived its repos in March 2026 and gated its images |
| GitHub Actions | **Forgejo Actions** | The hosted service is proprietary (its runner is MIT). Forgejo executes GHA-compatible YAML on an open runner, so the syntax transfers |
| Artifactory | **Harbor** | Artifactory is proprietary; Harbor is CNCF |
| Elastic Stack | **Loki** (+ OpenSearch) | Loki fits on a laptop; OpenSearch is the opt-in heavy profile |

Observability is taught on the **OpenTelemetry Collector** as the spine, with a
dedicated **Vector/VRL** lesson for log transformation — VRL is materially
better at log shaping, OTTL is better when the same pipeline carries traces and
metrics, and the lesson pair makes you feel the difference rather than telling
you about it.

## How the sandboxes work

Each lesson names a compose stack in `sandboxes/`:

| Stack | Contents |
|---|---|
| `linux-box` | One Debian container running **real systemd**, so `systemctl` and `journalctl` are the real thing |
| `chaos-stack` | Two services with **toxiproxy** between them, plus k6 |
| `ci-stack` | Forgejo + act_runner + Harbor |
| `none` | No stack — a scratch directory, for lessons where you write the Dockerfile |

Lessons in the resilience modules declare an extra `inject_fault` task that runs
*after* your work and *before* the check. That's what turns "make the broken
thing work" into "prove the working thing survives". You're always told when a
lesson does this.

## Contributing a lesson

A lesson is a directory with `index.md` (frontmatter: the sandbox and the task
scripts), `unit-1.md` (the prose, hints, and walkthrough), and
`solution/solve.sh` (the reference fix).

CI runs a contract test over every lesson:

1. bring the sandbox up clean, run `init_scenario`
2. assert `verify_done` **fails** — proving the lesson is really broken
3. apply `solution/solve.sh`
4. assert `verify_done` **passes** — proving it's really solvable
5. assert it passes **again** — proving the check has no side effects

Step 2 is the important one. A check that passes before the student does
anything is worse than no check: it teaches that the grader is meaningless.

```bash
mise run test        # fast, no Docker
mise run contract    # the real thing, needs Docker, takes minutes
```

Checks must fail with a `not yet: <specific reason>` line. The reason is the
teaching moment — `not yet: wrong` helps nobody.

## Licence

MIT.
