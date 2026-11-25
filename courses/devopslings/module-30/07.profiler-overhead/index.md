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

      cfg = configparser.ConfigParser()
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
    timeout_seconds: 180
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

      cfg = configparser.ConfigParser()
      cfg.read("/obs/quotes/profiling.ini")
      if not cfg.has_section("pyroscope") or not cfg["pyroscope"].getboolean("enabled", fallback=False):
          no("profiling is switched off in /obs/quotes/profiling.ini. That removes the overhead and the",
             "production profiles with it; the job is to keep them at a price worth paying.")
      live = cfg["pyroscope"].getint("sample_rate", fallback=100)
      if live != rate:
          no(f"your answer says sample_rate={rate}, and /obs/quotes/profiling.ini runs {live}.")
      if claimed >= 2:
          no(f"overhead_percent={claimed}: by your own measurement this rate costs 2% or more.")

      r = subprocess.run("taskset -c 0 python3 /obs/quotes/service.py --bench 5", shell=True,
                         capture_output=True, text=True, timeout=60)
      try:
          cost = json.loads(r.stdout.strip().splitlines()[-1])["profiler_cpu_percent"]
      except (IndexError, ValueError, KeyError):
          no("/obs/quotes/service.py --bench does not run:", *r.stderr.strip().splitlines()[-3:])
      print(f"this check ran quotes for 5 s on one CPU at {rate} Hz: the profiler's threads used {cost}% of its CPU")
      if cost >= 2:
          no(f"at {rate} samples a second the profiler takes {cost}% of the CPU from a service that has",
             "one. Each sample walks every thread's stack; the cost is per sample.")

      # The profile has to stay useful: enough samples since the change to name the hot path.
      started = int(open("/obs/run/quotes.started").read())
      time.sleep(max(0, started + 25 - time.time()))
      q = 'process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name="quotes"}'
      url = "http://pyroscope:4040/pyroscope/render?" + urllib.parse.urlencode(
          {"query": q, "from": str(started), "until": "now", "format": "json"})
      fb = json.load(urllib.request.urlopen(url, timeout=15))["flamebearer"]
      # Ticks are CPU nanoseconds; each sample stands for 1/rate seconds of it.
      names, total, width = fb["names"], round(fb["numTicks"] * rate / 1e9), {}
      for level in fb["levels"]:
          for i in range(0, len(level), 4):
              n = names[level[i + 3]]
              width[n] = width.get(n, 0) + level[i + 1]
      share = 100 * width.get("risk_score", 0) / fb["numTicks"] if fb["numTicks"] else 0
      print(f"Pyroscope since the last restart: {total} samples, risk_score in {share:.0f}% of them")
      if total < 100:
          no(f"Pyroscope has {total} samples of quotes since it restarted on this config. At that rate a",
             "profile cannot tell a 5% function from noise; the hot path has to stay visible.")
      if share < 50:
          no(f"risk_score, the known hot function, is in only {share:.0f}% of the samples Pyroscope holds.")
      print(f"PASS — at {rate} Hz the profiler costs {cost}% of the CPU (you measured {claimed}%), and its")
      print(f"       profile still puts risk_score in {share:.0f}% of {total} samples.")
      PY
---
