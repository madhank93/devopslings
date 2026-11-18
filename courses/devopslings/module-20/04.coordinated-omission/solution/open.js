import http from 'k6/http';

export const options = {
  scenarios: {
    production: {
      executor: 'constant-arrival-rate',
      rate: 100, timeUnit: '1s', duration: '30s',
      preAllocatedVUs: 50, maxVUs: 300,
    },
  },
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
};

export default function () {
  http.get('http://checkout:8200/search');
}
