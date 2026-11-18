// Spike: normal load, a jump to 600 a second in 2s, held 8s, then back.
import http from 'k6/http';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      startRate: 100, timeUnit: '1s',
      preAllocatedVUs: 100, maxVUs: 1000,
      stages: [
        { duration: '5s', target: 100 },
        { duration: '2s', target: 600 },
        { duration: '8s', target: 600 },
        { duration: '2s', target: 100 },
        { duration: '5s', target: 100 },
      ],
    },
  },
  thresholds: { http_req_failed: ['rate<0.01'] },
};

export default function () {
  http.get(`http://checkout:8250/quote?to=${__ITER % 90}`, { timeout: '10s' });
}
