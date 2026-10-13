// A surge to 3x what api can serve: 120 requests a second against 40. Checkout
// alone is well inside capacity; the excess is all recommendations.
import http from 'k6/http';
import { check } from 'k6';

const API = 'http://checkout:8100';

export const options = {
  summaryTrendStats: ['avg', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    // Open model: arrivals do not slow down because api is struggling.
    checkout: {
      executor: 'constant-arrival-rate', exec: 'checkout',
      rate: 15, timeUnit: '1s', duration: '20s', preAllocatedVUs: 30, maxVUs: 150,
    },
    recommendations: {
      executor: 'constant-arrival-rate', exec: 'recommendations',
      rate: 105, timeUnit: '1s', duration: '20s', preAllocatedVUs: 150, maxVUs: 600,
    },
  },
  thresholds: {
    // The revenue path is served, and served at normal speed.
    'checks{route:checkout}': ['rate>0.99'],
    'http_req_duration{route:checkout}': ['p(99)<500'],
    // The excess is refused quickly rather than left to wait.
    'http_req_duration{route:recommendations}': ['p(99)<500'],
    // Degraded, not switched off: spare capacity still serves recommendations.
    'http_reqs{route:recommendations,status:200}': ['count>=150'],
  },
};

export function checkout() {
  const r = http.get(`${API}/checkout`, { timeout: '5s', tags: { route: 'checkout' } });
  check(r, { 'checkout served': (r) => r.status === 200 }, { route: 'checkout' });
}

export function recommendations() {
  http.get(`${API}/recommendations`, { timeout: '5s', tags: { route: 'recommendations' } });
}

export function handleSummary(d) {
  const v = (m, k) => (d.metrics[m] ? d.metrics[m].values[k] : -1);
  return { stdout: [
    `checkout_ok=${v('checks{route:checkout}', 'rate')}`,
    `checkout_p99=${Math.round(v('http_req_duration{route:checkout}', 'p(99)'))}`,
    `recs_p99=${Math.round(v('http_req_duration{route:recommendations}', 'p(99)'))}`,
    `recs_served=${v('http_reqs{route:recommendations,status:200}', 'count')}`,
  ].join('\n') + '\n' };
}
