// The load test everyone runs: ramp from 10 to 150 quotes a second over 20s,
// then hold for 5s. Production peaks at about 100 a second.
import http from 'k6/http';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 10, timeUnit: '1s',
      preAllocatedVUs: 50, maxVUs: 400,
      stages: [
        { duration: '20s', target: 150 },
        { duration: '5s', target: 150 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<300'],
  },
};

export default function () {
  http.get(`http://checkout:8250/quote?to=${__ITER % 90}`, { timeout: '10s' });
}
