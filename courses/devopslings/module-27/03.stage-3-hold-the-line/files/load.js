// Customers at a constant rate, whatever production does: a slow or failing
// www does not slow the arrivals down, so every second of trouble is counted.
import http from "k6/http";

export const options = {
  scenarios: {
    www: {
      executor: "constant-arrival-rate",
      rate: 40,
      timeUnit: "1s",
      duration: __ENV.DURATION || "150s",
      preAllocatedVUs: 40,
      maxVUs: 300,
    },
  },
  discardResponseBodies: true,
  summaryTrendStats: ["p(99)", "max"],
};

export default function () {
  const r = http.get("http://www/", { timeout: "2s" });
  // When each failure or slow answer happened, so the grader can place it on
  // the timeline.
  const t = Math.floor(Date.now() / 1000);
  if (r.error_code || r.status >= 500) console.log(`fail ${t}`);
  else if (r.timings.duration > 500) console.log(`slow ${t}`);
}

export function handleSummary(d) {
  const m = d.metrics;
  return {
    stdout:
      JSON.stringify({
        reqs: m.http_reqs.values.count,
        failed: m.http_req_failed.values.passes,
        p99: Math.round(m.http_req_duration.values["p(99)"]),
      }) + "\n",
  };
}
