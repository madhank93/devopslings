// Month-end peak: 150 invoices a second for 30 seconds, open model.
import http from 'k6/http';

export const options = {
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
  scenarios: {
    peak: {
      executor: 'constant-arrival-rate',
      rate: 150, timeUnit: '1s', duration: '30s',
      preAllocatedVUs: 100, maxVUs: 1500,
    },
  },
};

export default function () {
  http.get('http://checkout:8240/render', { timeout: '30s' });
}
