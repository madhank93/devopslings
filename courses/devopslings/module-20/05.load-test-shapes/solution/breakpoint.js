// Breakpoint: raise the rate by 20 a second, every second, until requests fail.
import http from 'k6/http';

export const options = {
  scenarios: {
    breakpoint: {
      executor: 'ramping-arrival-rate',
      startRate: 100, timeUnit: '1s',
      preAllocatedVUs: 100, maxVUs: 1500,
      stages: [{ duration: '35s', target: 800 }],
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true }],
  },
};

export default function () {
  http.get(`http://checkout:8250/quote?to=${__ITER % 90}`, { timeout: '10s' });
}
