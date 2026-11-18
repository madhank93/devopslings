// The team's nightly latency report: one virtual user sends a request, waits
// for the answer, sends the next.
import http from 'k6/http';

export const options = {
  vus: 1,
  duration: '30s',
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
};

export default function () {
  http.get('http://checkout:8200/search');
}
