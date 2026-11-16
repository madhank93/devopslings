// Stage 2 of the cart pipeline: load-test the candidate on staging.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    shoppers: {
      executor: 'constant-arrival-rate',
      rate: 50, timeUnit: '1s', duration: '15s',
      preAllocatedVUs: 20, maxVUs: 100,
    },
  },
};

export default function () {
  const r = http.get('http://checkout:8210/cart');
  check(r, { 'cart loaded': (r) => r.status === 200 });
}
