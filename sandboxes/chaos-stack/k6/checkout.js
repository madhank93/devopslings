// Load profile for the timeout lesson.
//
// The thresholds are the grade. k6 exits non-zero when any of them is breached,
// so this script *is* the check — no wrapper parses its output.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 10,
  duration: '15s',

  thresholds: {
    // The point of the lesson. With the dependency hung, a caller that has no
    // timeout blocks until something upstream gives up; one that does have a
    // timeout fails fast and answers.
    http_req_duration: ['p(95)<3000'],

    // A fast 503 is still a failure to the customer. Surviving the fault means
    // continuing to answer, so a fallback is required to clear this.
    checks: ['rate>0.95'],
  },
};

export default function () {
  // Generous client-side ceiling: we are measuring the service's own timeout
  // behaviour, and cutting the request off ourselves would hide it.
  const res = http.get('http://checkout:8080/checkout', { timeout: '30s' });

  check(res, {
    'answered 200': (r) => r.status === 200,
    'has a price': (r) => {
      try {
        return typeof r.json().price === 'number';
      } catch {
        return false;
      }
    },
  });
}
