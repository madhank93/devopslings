// Steady traffic through the load balancer while a rolling deploy restarts
// both replicas. The grade is zero failed requests.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 20,
  duration: '45s',
  thresholds: {
    http_req_failed: ['rate==0'],
    checks: ['rate==1'],
  },
};

export default function () {
  // One request in ten is a multi-second export: the in-flight work a replica
  // is holding when SIGTERM arrives.
  const ms = Math.random() < 0.1 ? 5000 : 300;
  const res = http.get(`http://lb:8080/order?ms=${ms}`, { timeout: '30s' });
  check(res, { 'order placed': (r) => r.status === 200 });
}
