// Soak: production's normal 100 quotes a second, held for 80s.
import http from 'k6/http';

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-arrival-rate',
      rate: 100, timeUnit: '1s', duration: '80s',
      preAllocatedVUs: 50, maxVUs: 400,
    },
  },
  thresholds: { http_req_failed: ['rate<0.01'] },
};

export default function () {
  http.get(`http://checkout:8250/quote?to=${__ITER % 90}`, { timeout: '10s' });
}
