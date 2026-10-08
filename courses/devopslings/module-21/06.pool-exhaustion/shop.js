// Two routes under one fault. The grade is about /browse, which never touches
// pricing: it has to stay fast while /checkout is flooded and pricing is slow.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    // Open model: arrivals do not wait for responses, so a slow route piles up
    // concurrency (rate x latency) instead of politely slowing its callers.
    checkout: {
      executor: 'constant-arrival-rate', exec: 'checkout',
      rate: 100, timeUnit: '1s', duration: '20s',
      preAllocatedVUs: 200, maxVUs: 600,
    },
    browse: {
      executor: 'constant-arrival-rate', exec: 'browse',
      rate: 10, timeUnit: '1s', duration: '20s',
      preAllocatedVUs: 20, maxVUs: 100,
    },
  },
  thresholds: {
    // The healthy route keeps serving.
    'http_req_duration{route:browse}': ['p(95)<500'],
    'checks{route:browse}': ['rate>0.99'],
    // The slow route still gets the work pricing can actually do — refusing
    // every checkout is not isolation, it is an outage of one route.
    'http_reqs{route:checkout,status:200}': ['count>=40'],
  },
};

export function checkout() {
  http.get('http://shop:8080/checkout', { timeout: '30s', tags: { route: 'checkout' } });
}

export function browse() {
  const res = http.get('http://shop:8080/browse', { timeout: '30s', tags: { route: 'browse' } });
  check(res, { 'browse answered 200': (r) => r.status === 200 }, { route: 'browse' });
}
