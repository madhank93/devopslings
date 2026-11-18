// 30 profile pages a second for 20 seconds, open model.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  summaryTrendStats: ['p(50)', 'p(90)', 'p(99)', 'max'],
  scenarios: {
    pages: {
      executor: 'constant-arrival-rate',
      rate: 30, timeUnit: '1s', duration: '20s',
      preAllocatedVUs: 30, maxVUs: 200,
    },
  },
  thresholds: {
    checks: ['rate==1'],
    http_req_duration: ['p(99)<200'],
  },
};

export default function () {
  const r = http.get('http://checkout:8220/profile', { timeout: '10s' });
  check(r, { 'page served': (r) => r.status === 200 });
}
