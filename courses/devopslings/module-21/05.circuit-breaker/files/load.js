// Sustained-fault load for the circuit-breaker lesson. Thresholds are the grade.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const pricingCalls = new Counter('pricing_calls');

export const options = {
  vus: 10,
  duration: '15s',
  thresholds: {
    // A working breaker spends the first wave of 10 discovering the fault, then
    // one trial per cooldown. Without one, every request goes to pricing.
    pricing_calls: ['count<=15'],
    // Failing fast: requests answered by an open breaker do not wait at all.
    http_req_duration: ['p(95)<500'],
    checks: ['rate>0.99'],
  },
};

export default function () {
  const res = http.get('http://checkout:8081/checkout', { timeout: '30s' });
  let body = {};
  try {
    body = res.json();
  } catch (e) {
    // a non-JSON answer fails the check below
  }
  if (body.called_pricing) pricingCalls.add(1);
  check(res, { 'answered with a price': (r) => r.status === 200 && typeof body.price === 'number' });
  sleep(0.05);
}
