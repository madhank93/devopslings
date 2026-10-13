// Traffic through the gateway for 25s. At 8s reviews slows by 3s per call and
// stays slow. Only the product page uses reviews; the grade is about the
// routes that never touch it.
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate } from 'k6/metrics';

const GATEWAY = 'http://checkout:8113';
const ADMIN = 'http://toxiproxy:8474/proxies/cascade-reviews';
const SERVICES = { gateway: 'http://checkout:8113', orders: 'http://checkout:8112',
                   product: 'http://checkout:8111', reviews: 'http://pricing:8110' };
const FAULT_AT = 8;

const reviewsShown = new Rate('reviews_shown_before_fault');
const starved = {};
for (const s of ['gateway', 'orders', 'product']) starved[s] = new Counter(`starved_${s}`);

const route = (name, rate) => ({
  executor: 'constant-arrival-rate', exec: name, rate, timeUnit: '1s', duration: '25s',
  preAllocatedVUs: rate * 2, maxVUs: rate * 6,
});

export const options = {
  summaryTrendStats: ['avg', 'p(95)', 'max'],
  scenarios: {
    product: route('product', 40),
    checkout: route('checkout', 20),
    account: route('account', 10),
    fault: { executor: 'per-vu-iterations', vus: 1, iterations: 1, startTime: `${FAULT_AT}s`, exec: 'slow' },
  },
  thresholds: {
    // Neither route calls reviews. They must not notice it is slow.
    'checks{route:account}': ['rate>0.99'],
    'http_req_duration{route:account}': ['p(95)<500'],
    'checks{route:checkout}': ['rate>0.99'],
    'http_req_duration{route:checkout}': ['p(95)<500'],
    // The product page still renders, without reviews if it has to.
    'checks{route:product}': ['rate>0.95'],
    'http_req_duration{route:product}': ['max>=0'],
    // On a normal day it renders with them.
    reviews_shown_before_fault: ['rate>0.97'],
  },
};

export function setup() {
  http.del(`${ADMIN}/toxics/slow`);
  for (const url of Object.values(SERVICES)) http.post(`${url}/reset`);
}

const get = (path, name) => http.get(`${GATEWAY}${path}`, { timeout: '5s', tags: { route: name } });

export function product() {
  const before = (Date.now() - exec.scenario.startTime) / 1000 < FAULT_AT;
  const r = get('/product', 'product');
  check(r, { 'product page rendered': (r) => r.status === 200 }, { route: 'product' });
  if (before && r.status === 200) reviewsShown.add(r.json('reviews') !== null);
}

export function checkout() {
  check(get('/checkout', 'checkout'), { 'order placed': (r) => r.status === 200 }, { route: 'checkout' });
}

export function account() {
  check(get('/account', 'account'), { 'account shown': (r) => r.status === 200 }, { route: 'account' });
}

export function slow() {
  http.post(`${ADMIN}/toxics`, JSON.stringify({ name: 'slow', type: 'latency', stream: 'downstream',
                                                 attributes: { latency: 3000 } }));
}

export function teardown() {
  http.del(`${ADMIN}/toxics/slow`);
  for (const s of Object.keys(starved)) starved[s].add(http.get(`${SERVICES[s]}/stats`).json('starved'));
}

export function handleSummary(d) {
  const v = (m, k) => (d.metrics[m] ? d.metrics[m].values[k] : -1);
  const lines = [];
  for (const r of ['account', 'checkout', 'product']) {
    lines.push(`${r}_ok=${v(`checks{route:${r}}`, 'rate')}`);
    lines.push(`${r}_p95=${Math.round(v(`http_req_duration{route:${r}}`, 'p(95)'))}`);
  }
  lines.push(`reviews_before=${v('reviews_shown_before_fault', 'rate')}`);
  for (const s of Object.keys(starved)) lines.push(`starved_${s}=${v(`starved_${s}`, 'count')}`);
  return { stdout: lines.join('\n') + '\n' };
}
