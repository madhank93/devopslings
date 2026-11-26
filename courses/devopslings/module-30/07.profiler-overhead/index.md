---
kind: lesson
title: "the profiler that cost 15% of the service"
description: |
  Continuous profiling went on for the quotes service at 1000 samples a
  second, and throughput fell 15%. The proposal is to turn it off, which
  throws away the production profiles everyone wanted. Measure what the
  profiler costs, choose a rate that costs under 2% and still finds the hot
  function, and show both.
name: profiler-overhead
slug: profiler-overhead
createdAt: "2026-11-22"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      # Stop every profiled app this module starts, whichever lesson left it running:
      # they share the CPU this lesson's numbers are read from.
      pkill -f '^bash [^ ]*/supervise (pricing|catalog-v[12]|quoter|quotes) ' 2>/dev/null || true
      pkill -f '^python3 /obs/(pricing|catalog|quoter|quotes)/' 2>/dev/null || true
      rm -rf /obs/quotes /obs/run/quotes.* /obs/logs/quotes.log
      mkdir -p /obs/quotes

      cat > /obs/quotes/service.py <<'PY'
      """quotes: prices insurance quotes, profiled to Pyroscope as configured in
      /obs/quotes/profiling.ini.

        service.py                    serve: price quotes, as production does
        service.py --bench S [--off]  price quotes flat out for S seconds, print quotes/s
                                      (--off: with the profiler not loaded at all)
      """
      import configparser, json, os, sys, threading, time

      cfg = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
      cfg.read("/obs/quotes/profiling.ini")
      prof = cfg["pyroscope"]
      if prof.getboolean("enabled", fallback=False) and "--off" not in sys.argv:
          import pyroscope
          # Benchmarks report under their own name, so production's profile stays production's.
          pyroscope.configure(application_name="quotes-bench" if "--bench" in sys.argv else "quotes",
                              server_address=os.environ.get("PYROSCOPE", "http://pyroscope:4040"),
                              sample_rate=prof.getint("sample_rate", fallback=100))

      # The request pool: idle between requests, sampled like every other thread.
      for i in range(16):
          threading.Thread(target=threading.Event().wait, name=f"pool-{i}", daemon=True).start()


      def risk_score(n):
          s = 0
          for i in range(n):
              s += (i * 7919) % 13
          return s


      def walk_rules(depth):
          """Descend the underwriting rule tree; the score is computed at the leaf."""
          return risk_score(20000) if depth == 0 else walk_rules(depth - 1)


      def price_quote():
          return walk_rules(40)


      def cpu_ticks():
          """CPU ticks per thread of this process, keyed by native thread id."""
          out = {}
          for t in os.listdir("/proc/self/task"):
              f = open(f"/proc/self/task/{t}/stat").read().rsplit(")", 1)[1].split()
              out[int(t)] = int(f[11]) + int(f[12])
          return out


      if "--bench" in sys.argv:
          secs = float(sys.argv[sys.argv.index("--bench") + 1])
          end = time.monotonic() + 1
          while time.monotonic() < end:
              price_quote()
          me, before = threading.get_native_id(), cpu_ticks()
          n, t0 = 0, time.monotonic()
          while time.monotonic() - t0 < secs:
              price_quote()
              n += 1
          after, wall = cpu_ticks(), time.monotonic() - t0
          others = sum(v - before.get(t, 0) for t, v in after.items() if t != me)
          # The profiler samples on the wall clock, so its cost is a share of the CPU over wall time.
          print(json.dumps({"quotes_per_s": round(n / wall, 1),
                            "profiler_cpu_percent": round(100 * others / (wall * os.sysconf("SC_CLK_TCK")), 2)}))
          sys.exit(0)

      while True:
          end = time.monotonic() + 0.5
          while time.monotonic() < end:
              price_quote()
          time.sleep(0.5)
      PY
      cat > /obs/quotes/profiling.ini <<'INI'
      [pyroscope]
      enabled = true
      # samples per second
      sample_rate = 1000
      INI
      chmod -R a+rX /obs/quotes
      (cd /obs/quotes && sha256sum service.py) > /obs/run/quotes.sums

      for _ in $(seq 1 60); do curl -fs -m 2 "$PYROSCOPE/ready" >/dev/null 2>&1 && break; sleep 1; done
      # The service's container is limited to one CPU; taskset stands in for that limit.
      setsid supervise quotes taskset -c 0 python3 /obs/quotes/service.py /obs/quotes/profiling.ini \
        </dev/null >/dev/null 2>&1 &
      sleep 2
      pgrep -f '^python3 /obs/quotes/service\.py' >/dev/null

      echo "scenario ready — quotes runs on one CPU and profiles itself to Pyroscope as"
      echo "service_name=\"quotes\" (http://localhost:14040), as /obs/quotes/profiling.ini says."
      echo "Benchmark it on the same CPU: taskset -c 0 python3 /obs/quotes/service.py --bench 5 [--off]"

  verify_done:
    timeout_seconds: 240
    run: |
      python3 - <<'PY'
      import configparser, json, subprocess, sys, time, urllib.parse, urllib.request

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      ans = {}
      try:
          for line in open("/obs/answers/overhead.txt"):
              if "=" in line:
                  k, v = line.split("=", 1)
                  ans[k.strip()] = v.strip().strip('"%')
      except OSError:
          pass
      if "sample_rate" not in ans or "overhead_percent" not in ans:
          no("/obs/answers/overhead.txt needs sample_rate=<Hz> and overhead_percent=<n>: the rate you",
             "chose, and the throughput it costs, measured profiler on against profiler off.")
      try:
          rate, claimed = int(ans["sample_rate"]), float(ans["overhead_percent"])
      except ValueError:
          no("sample_rate must be a whole number of samples a second and overhead_percent a number.")

      cfg = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
      try:
          cfg.read("/obs/quotes/profiling.ini")
          enabled = cfg.has_section("pyroscope") and cfg["pyroscope"].getboolean("enabled", fallback=False)
          live = cfg["pyroscope"].getint("sample_rate", fallback=100) if enabled else None
      except (configparser.Error, ValueError) as e:
          no(f"/obs/quotes/profiling.ini does not parse: {e}")
      if not enabled:
          no("profiling is switched off in /obs/quotes/profiling.ini. That removes the overhead and the",
             "production profiles with it; the job is to keep them at a price worth paying.")
      if live != rate:
          no(f"your answer says sample_rate={rate}, and /obs/quotes/profiling.ini runs {live}.")
      if claimed >= 2:
          no(f"overhead_percent={claimed}: by your own measurement this rate costs 2% or more.")

      if subprocess.run("cd /obs/quotes && sha256sum -c --quiet /obs/run/quotes.sums", shell=True,
                        capture_output=True).returncode != 0:
          no("/obs/quotes/service.py has changed. The rate is the knob, in profiling.ini; the check",
             "measures the service as shipped.")

      def bench():
          try:
              r = subprocess.run("taskset -c 0 python3 /obs/quotes/service.py --bench 5", shell=True,
                                 capture_output=True, text=True, timeout=30)
          except subprocess.TimeoutExpired:
              no("/obs/quotes/service.py --bench 5 ran for over 30 s.")
          try:
              return json.loads(r.stdout.strip().splitlines()[-1])["profiler_cpu_percent"]
          except (IndexError, ValueError, KeyError):
              no("/obs/quotes/service.py --bench does not run:", *r.stderr.strip().splitlines()[-3:])
      cost = sorted(bench() for _ in range(3))[1]
      print(f"this check ran quotes three times for 5 s on one CPU at {rate} Hz: the profiler's threads used {cost}% of its CPU (median)")
      if cost >= 2:
          no(f"at {rate} samples a second the profiler takes {cost}% of the CPU from a service that has",
             "one. Each sample walks every thread's stack; the cost is per sample.")
      if abs(claimed - cost) > 1:
          no(f"overhead_percent={claimed}, and this check measured {cost}% at {rate} Hz. Measure on against",
             "off at the rate you chose, alternating, and write what you measured.")

      # The profile has to stay useful: enough samples in the first 25 s after the change to
      # name the hot path. A fixed window, so uptime cannot make up for a rate too low.
      # Profiles reach Pyroscope some seconds after they are taken: read until the count settles.
      started = int(open("/obs/run/quotes.started").read())
      q = 'process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name="quotes"}'
      url = "http://pyroscope:4040/pyroscope/render?" + urllib.parse.urlencode(
          {"query": q, "from": str(started), "until": str(started + 25), "format": "json"})
      time.sleep(max(0, started + 30 - time.time()))
      fb, prev, deadline = {}, -1, started + 90
      while True:
          try:
              fb = json.load(urllib.request.urlopen(url, timeout=15)).get("flamebearer") or {}
          except (OSError, ValueError):
              fb = {}
          ticks = fb.get("numTicks") or 0
          settled = ticks and ticks == prev
          if settled or time.time() > deadline:
              break
          prev = ticks
          time.sleep(5)
      # Ticks are CPU nanoseconds; each sample stands for 1/rate seconds of it.
      names, total, width = fb.get("names") or [], round(ticks * rate / 1e9), {}
      for level in fb.get("levels") or []:
          for i in range(0, len(level), 4):
              n = names[level[i + 3]]
              width[n] = width.get(n, 0) + level[i + 1]
      share = 100 * width.get("risk_score", 0) / ticks if ticks else 0
      print(f"Pyroscope, first 25 s after the last restart: {total} samples, risk_score in {share:.0f}% of them")
      if total < 100 and not settled:
          no(f"Pyroscope has {total} samples of quotes for the 25 s after it restarted, and the count was",
             "still changing (or empty) 90 s after the restart: the profiles have not been ingested yet.",
             "Check /obs/logs/quotes.log and Pyroscope, then run the check again.")
      if total < 100:
          no(f"Pyroscope has {total} samples of quotes in the 25 s after it restarted on this config. At that rate a",
             "profile cannot tell a 5% function from noise; the hot path has to stay visible.")
      if share < 50:
          no(f"risk_score, the known hot function, is in only {share:.0f}% of the samples Pyroscope holds.")
      print(f"PASS — at {rate} Hz the profiler costs {cost}% of the CPU (you measured {claimed}%), and its")
      print(f"       profile still puts risk_score in {share:.0f}% of {total} samples.")
      PY
---
