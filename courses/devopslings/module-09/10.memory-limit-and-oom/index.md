---
kind: lesson
title: "the job dies at exactly the same input size, with no error"
description: |
  Exit 137, no stack trace, no log line. It is not a leak — memory use is
  proportional to the input and the job dies at the same place every run. Learn
  what the JVM believes about its container, and why a heap setting above the
  limit turns a diagnosable error into a silent kill.
name: memory-limit-and-oom
slug: memory-limit-and-oom
createdAt: "2026-09-01"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      proj=devopslings-oom

      cat > Main.java <<'JAVA'
      import java.util.ArrayList;
      import java.util.List;

      /** Nightly customer aggregation. Memory use is proportional to the input. */
      public class Main {
          record Customer(int id, String name, String region) {}

          public static void main(String[] args) {
              int n = Integer.parseInt(System.getenv().getOrDefault("RECORDS", "8000000"));
              System.out.println("heap max " + Runtime.getRuntime().maxMemory() / (1024 * 1024) + "MB");

              List<Customer> live = new ArrayList<>(n);
              for (int i = 0; i < n; i++) live.add(new Customer(i, "customer-" + i, "emea"));
              System.out.println("loaded " + live.size() + " records");

              long total = 0;
              for (int pass = 0; pass < 40; pass++) {
                  List<String> scratch = new ArrayList<>(200000);
                  for (int i = 0; i < 200000; i++) scratch.add("row-" + i);
                  total += scratch.size();
              }
              System.out.println("aggregated " + total + " rows across " + live.size() + " customers");
          }
      }
      JAVA

      cat > Dockerfile <<'DOCKER'
      FROM eclipse-temurin:21-jdk
      WORKDIR /app
      COPY Main.java .
      CMD ["java", "Main.java"]
      DOCKER

      # The limit was set when the job was small, and the heap flag was copied
      # from the machine someone ran it on by hand.
      cat > compose.yaml <<'YAML'
      services:
        aggregator:
          build: .
          mem_limit: 512m
          environment:
            RECORDS: "8000000"
            JDK_JAVA_OPTIONS: "-Xmx1g"
      YAML

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it:"
      echo "  docker compose -p $proj run --rm aggregator; echo \"exit \$?\""

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      proj=devopslings-oom
      budget=1073741824   # 1 GiB — what the node pool gives this job
      headroom=134217728  # 128 MiB the JVM needs outside the heap

      for f in Main.java Dockerfile compose.yaml; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      if ! build_out=$(docker compose -p "$proj" build 2>&1); then
        echo "not yet: the image does not build:"
        printf '%s\n' "$build_out" | tail -12 | sed 's/^/    /'
        exit 1
      fi

      # The limit the kernel will actually enforce, read from inside the
      # container rather than from the compose file.
      limit=$(docker compose -p "$proj" run --rm --entrypoint sh aggregator -c \
        'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' \
        2>/dev/null | tr -d '\r' | tail -1)

      case "$limit" in
        ''|max|*[!0-9]*)
          echo "not yet: this container has no memory limit. Running it unlimited makes"
          echo "the job survive on a laptop and take the node down in production —"
          echo "the limit is the contract, and it has to be one the job fits in."
          exit 1
          ;;
      esac

      if [ "$limit" -gt "$budget" ]; then
        echo "not yet: the limit is $((limit / 1048576))MB and this job's budget is"
        echo "$((budget / 1048576))MB. Raising the limit until the problem goes away is"
        echo "not the exercise — the job has to fit in what the node pool gives it."
        exit 1
      fi

      # The heap ceiling the JVM will actually use, read from the JVM rather than
      # from the compose file, so however it is configured is what gets measured.
      heap=$(docker compose -p "$proj" run --rm --entrypoint java aggregator \
        -XX:+PrintFlagsFinal -version 2>/dev/null \
        | awk '/ MaxHeapSize/ {print $4}' | tail -1)

      if [ -z "${heap:-}" ]; then
        echo "not yet: could not read MaxHeapSize back from the JVM"
        exit 1
      fi

      if [ "$heap" -gt "$((limit - headroom))" ]; then
        echo "not yet: the heap ceiling is $((heap / 1048576))MB inside a $((limit / 1048576))MB"
        echo "container. A JVM is not only its heap — metaspace, thread stacks, code"
        echo "cache and buffers all live outside it, so a heap that reaches the limit"
        echo "means the kernel gets there first. Leave at least $((headroom / 1048576))MB."
        exit 1
      fi

      # The exit status has to be captured from the command, not from inside an
      # `if !`, where $? is the negation's own status and always 0.
      code=0
      out=$(docker compose -p "$proj" run --rm aggregator 2>&1) || code=$?
      if [ "$code" != "0" ]; then
        echo "not yet: the job still fails (exit $code):"
        # A JVM stack trace is mostly frames; the line that says what happened is
        # the one worth putting in front of someone.
        if printf '%s' "$out" | grep -q 'OutOfMemoryError'; then
          printf '%s\n' "$out" | grep -m1 'OutOfMemoryError' | sed 's/^/    /'
        else
          printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
        fi
        if [ "$code" = "137" ]; then
          echo "137 is the kernel killing it. The heap fits the limit now, so the"
          echo "container needs more than the heap: check what else is in that $((limit / 1048576))MB."
        else
          echo "The heap ceiling may now be below what this input genuinely needs."
        fi
        exit 1
      fi

      case "$out" in
        *"aggregated 8000000 rows across 8000000 customers"*) ;;
        *)
          echo "not yet: the job exited 0 without finishing the aggregation:"
          printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
          exit 1
          ;;
      esac

      # The other half of agreeing: when the input really is too big, the failure
      # has to be one someone can read.
      probe=$(docker compose -p "$proj" run --rm -e RECORDS=20000000 aggregator 2>&1) || probe_code=$?
      probe_code=${probe_code:-0}

      if [ "$probe_code" = "0" ]; then
        echo "not yet: an input of 20,000,000 records completed, which it cannot do in"
        echo "$((limit / 1048576))MB. Is RECORDS still being read from the environment?"
        exit 1
      fi
      if [ "$probe_code" = "137" ]; then
        echo "not yet: the normal input passes, and 20,000,000 records still gets the"
        echo "container killed with 137 and no message. The heap ceiling is still above"
        echo "what the container can actually give, so the kernel reaches the end of the"
        echo "memory before the JVM does."
        exit 1
      fi
      case "$probe" in
        *OutOfMemoryError*) ;;
        *)
          echo "not yet: 20,000,000 records failed with $probe_code and no OutOfMemoryError:"
          printf '%s\n' "$probe" | tail -8 | sed 's/^/    /'
          exit 1
          ;;
      esac

      echo "PASS — the job completes in $((limit / 1048576))MB with a $((heap / 1048576))MB heap,"
      echo "and an input that does not fit now says so instead of vanishing."
---
