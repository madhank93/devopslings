# k6 inspect output -> the load profile of its first scenario, in requests a
# second: total seconds, peak rate, seconds held at 200+, and whether any stage
# jumps at least fourfold to 400+ within 5 seconds.
def secs: [scan("([0-9.]+)(ms|h|m|s)")] | map((.[0] | tonumber) * ({"ms": 0.001, "s": 1, "m": 60, "h": 3600}[.[1]])) | add // 0;
. as $root
| ([.scenarios // {} | .[]][0]) as $s
| if $s == null then {exec: "none", segs: []}
  else (($s.timeUnit // "1s") | secs) as $tu
  | if $s.executor == "constant-arrival-rate" then
      {exec: $s.executor, segs: [{d: ($s.duration | secs), from: ($s.rate / $tu), to: ($s.rate / $tu)}]}
    elif $s.executor == "ramping-arrival-rate" then
      {exec: $s.executor, segs: (reduce ($s.stages // [])[] as $st ({p: (($s.startRate // 0) / $tu), a: []};
        .a += [{d: ($st.duration | secs), from: .p, to: ($st.target / $tu)}] | .p = ($st.target / $tu)) | .a)}
    else {exec: $s.executor, segs: []} end
  end
| .total = ([.segs[].d] | add // 0)
| .peak = ([.segs[] | .from, .to] | max // 0)
| .held200 = ([.segs[] | select(.from >= 200 and .to >= 200) | .d] | add // 0)
| .spike = ([.segs[] | select(.to >= 400 and .to >= 4 * .from and .d <= 5)] | length > 0)
| .abort = ([$root.thresholds // {} | .[][] | objects | select(.abortOnFail == true)] | length > 0)
