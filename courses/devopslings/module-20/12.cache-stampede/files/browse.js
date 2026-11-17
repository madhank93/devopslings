// Shoppers browsing the 20 products: 300 requests a second for 35 seconds,
// open model. Each response says when catalog-db produced it.
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const staleness = new Trend('staleness_s');

export const options = {
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
  scenarios: {
    shoppers: {
      executor: 'constant-arrival-rate',
      rate: 300, timeUnit: '1s', duration: '35s',
      preAllocatedVUs: 100, maxVUs: 1000,
    },
  },
};

export default function () {
  const r = http.get(`http://checkout:8230/product/${Math.floor(Math.random() * 20)}`, { timeout: '20s' });
  if (check(r, { 'served': (r) => r.status === 200 })) {
    staleness.add(Date.now() / 1000 - r.json('fetched_at'));
  }
}
