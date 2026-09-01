---
title: "the job dies at exactly the same input size, with no error"
---

## The situation

The nightly aggregation stopped finishing. There is no stack trace, no error
line, nothing in the log after `loaded 8000000 records`:

```
$ docker compose -p devopslings-oom run --rm aggregator
NOTE: Picked up JDK_JAVA_OPTIONS: -Xmx1g
heap max 989MB
loaded 8000000 records
exit 137
```

The first guess in the channel is a memory leak. It is not one, and you can say
so from the evidence already here: a leak grows with time, and this dies at the
same input size every run, on the same line, in the same second. Memory use is
proportional to the input, and the input got bigger.

Two numbers in that output disagree with each other, and neither is the app's
fault:

```
$ grep -E 'mem_limit|Xmx' compose.yaml
    mem_limit: 512m
      JDK_JAVA_OPTIONS: "-Xmx1g"
```

## Your objectives

1. Make the job finish.
2. Make it finish inside 1 GiB, which is what the node pool gives it. Raising
   the limit until the problem disappears is not available.
3. Make an input that genuinely does not fit fail with an error someone can
   read, instead of the container vanishing.

## What you're being graded on

The grader reads the enforced limit from the container's own cgroup and the
heap ceiling back out of the JVM, so however you configure them is what gets
measured: the limit must exist and be within budget, the heap must leave the
JVM room to be a JVM, and the job must complete. Then it runs the same image
with 20,000,000 records and requires that to fail with an `OutOfMemoryError`
rather than exit 137.

<details>
<summary>Hint 1 — what 137 is</summary>

128 + 9. Signal 9, `SIGKILL`, sent by the kernel's OOM killer. Nothing in the
process chose it, which is why nothing was logged: the process was not asked to
stop, it was removed.

The kernel kills a container when the cgroup hits its memory limit. So the
question is not "what did the app do wrong" but "what did the app believe it
was allowed to use".

</details>

<details>
<summary>Hint 2 — ask the JVM what it thinks it has</summary>

The first line the job prints is `Runtime.maxMemory()`, which is a little under
`-Xmx` because part of the heap is bookkeeping. You can also ask
without running the job:

```
docker compose -p devopslings-oom run --rm --entrypoint java aggregator \
  -XX:+PrintFlagsFinal -version | grep -E 'MaxHeapSize|UseContainerSupport'
```

Compare that number with `mem_limit`. A JVM told it may use a gigabyte of heap
will go and use it, and the kernel is under no obligation to agree.

Then work out how much the job actually needs: the live set is about 650 MB and
you cannot make it smaller without changing the job.

</details>

<details>
<summary>Hint 3 — the heap is not the process</summary>

Setting `-Xmx` equal to the limit does not work either. Alongside the Java heap,
the same container holds metaspace, thread stacks, the JIT code cache, GC
structures and direct buffers — comfortably a hundred megabytes of things that
are not the heap and are still in the cgroup.

So the heap ceiling has to be under the limit by enough to hold everything else,
and the limit has to be over the live set by enough to hold the heap.

</details>

<details>
<summary>Solution</summary>

```yaml
services:
  aggregator:
    build: .
    mem_limit: 1g
    environment:
      RECORDS: "8000000"
      JDK_JAVA_OPTIONS: "-Xmx700m"
```

```
$ docker compose -p devopslings-oom run --rm aggregator
heap max 676MB
loaded 8000000 records
aggregated 8000000 rows across 8000000 customers

$ docker compose -p devopslings-oom run --rm -e RECORDS=20000000 aggregator
Exception in thread "main" java.lang.OutOfMemoryError: Java heap space
        at java.base/jdk.internal.misc.Unsafe.allocateUninitializedArray(Unsafe.java:1380)
        at java.base/java.lang.StringConcatHelper.newArray(StringConcatHelper.java:511)
```

The second command is the part worth looking at twice. The job still fails —
20 million records do not fit in 700 MB and nothing can make them — but it now
fails *inside the JVM*, with the exception type, the line number, and a heap
dump if you ask for one. Before, the same input produced exit 137 and silence.

### The part worth remembering

**Two limits, and the smaller one decides how you find out.**

- If `-Xmx` is **above** what the container can give, the JVM allocates happily
  toward its own ceiling, crosses the cgroup limit on the way, and the kernel
  kills the process. No exception, no stack, no heap dump — the JVM never got to
  react, and 137 is all you get.
- If `-Xmx` is **below** the limit with room to spare, the JVM hits its own
  ceiling first and raises `OutOfMemoryError`, which is a Java-level event: it
  has a stack trace, it can trigger `-XX:+HeapDumpOnOutOfMemoryError`, and it
  tells you which allocation could not be served.

Both are failures. Only one is a diagnosis. Tuning the heap under the limit is
not only about fitting — it is about which of your two subsystems notices first.

A modern JVM does read the cgroup: `UseContainerSupport` is on by default and,
with no `-Xmx`, it sizes the heap to a fraction of the container limit
(`MaxRAMPercentage`, 25% by default). That default is safe and often far too
small — 25% of 1 GiB is 256 MB, which this job cannot run in. So the choice is
to set `-Xmx` explicitly below the limit, or set `-XX:MaxRAMPercentage=70` and
let it scale with whatever limit the platform hands you. The second travels
better across environments; the first is easier to reason about. What is not an
option is an `-Xmx` copied from a laptop, which is how this one got here.

The same shape appears everywhere a runtime has its own memory ceiling: Node's
`--max-old-space-size` (though current V8 does clamp itself to the cgroup),
Python worker counts multiplied by per-worker footprint, Go's `GOMEMLIMIT`. And
the general rule holds even where there is no ceiling to set: **a container
memory limit is a contract about the whole process**, not about the part of it
your language calls the heap.

</details>
