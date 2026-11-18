// Stress: two and a half times normal, 250 a second, held for 20s.
import http from 'k6/http';

export const options = {
  scenarios: {
    stress: {
      executor: 'ramping-arrival-rate',
      startRate: 100, timeUnit: '1s',
      preAllocatedVUs: 100, maxVUs: 600,
      stages: [
        { duration: '5s', target: 250 },
        { duration: '20s', target: 250 },
      ],
    },
  },
  thresholds: { http_req_failed: ['rate<0.01'], http_req_duration: ['p(95)<300'] },
};

export default function () {
  http.get(`http://checkout:8250/quote?to=${__ITER % 90}`, { timeout: '10s' });
}
