// The game day: a replay of the pricing incident against shop, 42 seconds.
//
//   steady  0-8s    20 checkouts/s; 5% of connections to pricing are reset
//   rush    8-18s   40 checkouts/s; pricing takes 1.5s per call
//   outage  18-28s  20 checkouts/s; pricing takes 8s per call (hung)
//   after   28-42s  20 checkouts/s; pricing healthy (graded from 36s)
//
// Browse runs at 10/s throughout. The thresholds are the grade; teardown()
// reads pricing's own counters, so what pricing received is graded too.
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter, Gauge } from 'k6/metrics';

const SHOP = 'http://checkout:8214';
const LEDGER = 'http://pricing:8214';
const ADMIN = 'http://toxiproxy:8474/proxies/triage-pricing';
const JSONH = { headers: { 'Content-Type': 'application/json' } };

const rushSold = new Counter('rush_sold');
const retried404 = new Counter('retried_404');
const outageCalls = new Gauge('outage_calls');

const rate = (r, start, dur, vus) => ({
  executor: 'constant-arrival-rate', exec: 'checkout', rate: r, timeUnit: '1s',
  startTime: start, duration: dur, preAllocatedVUs: vus, maxVUs: 300,
});

export const options = {
  scenarios: {
    steady: rate(20, '0s', '8s', 20),
    rush: rate(40, '8s', '10s', 80),
    outage: rate(20, '18s', '10s', 60),
    after: rate(20, '28s', '14s', 40),
    browse: { executor: 'constant-arrival-rate', exec: 'browse', rate: 10, timeUnit: '1s',
              duration: '42s', preAllocatedVUs: 20, maxVUs: 300 },
    incident: { executor: 'per-vu-iterations', exec: 'incident', vus: 1, iterations: 1,
                maxDuration: '60s' },
  },
  thresholds: {
    // Resets are retried: with nothing slow, every customer gets pricing's answer.
    'checks{phase:steady}': ['rate>0.99'],
    // While pricing is slow or hung, every customer still gets an answer.
    'checks{phase:rush}': ['rate>0.99'],
    'checks{phase:outage}': ['rate>0.99'],
    // Once pricing is back, customers get pricing's answer again.
    'checks{phase:after}': ['rate>0.95'],
    // Nobody waits longer than the 3s checkout budget, at any point.
    'http_req_duration{route:checkout}': ['max<3000'],
    // Browse never needs pricing, and stays fast through all of it.
    'http_req_duration{route:browse}': ['p(95)<500'],
    'checks{route:browse}': ['rate>0.99'],
    // Slow is not broken: pricing's 1.5s answers are still used.
    rush_sold: ['count>=30'],
    // pricing never sees a request it already answered 404.
    retried_404: ['count<1'],
    // pricing is left alone while it is down.
    outage_calls: ['value<=20'],
  },
};

export function setup() {
  http.post(`${LEDGER}/reset`);
}

export function checkout() {
  const scen = exec.scenario.name;
  const t = (Date.now() - exec.scenario.startTime) / 1000;
  const phase = scen === 'after' && t < 8 ? 'recovering' : scen;
  const sku = Math.random() < 0.1 ? 'retired' : 'widget';
  const r = http.get(`${SHOP}/checkout?sku=${sku}`, {
    timeout: '30s', headers: { 'X-Phase': phase }, tags: { route: 'checkout', phase },
  });
  let body = {};
  try { body = r.json(); } catch (e) { /* not JSON: fails below */ }
  const priced = r.status === 200 && typeof body.price === 'number';
  const fromPricing = (sku === 'retired' && r.status === 404) || (priced && body.source === 'pricing');
  if (phase === 'rush' && priced && body.source === 'pricing') rushSold.add(1);
  const ok = phase === 'steady' || phase === 'after' ? fromPricing
    : (sku === 'retired' && r.status === 404) || priced;
  check(r, { 'checkout answered': () => ok }, { phase });
}

export function browse() {
  const r = http.get(`${SHOP}/browse`, { timeout: '30s', tags: { route: 'browse' } });
  check(r, { 'browse answered': (res) => res.status === 200 }, { route: 'browse' });
}

function mark(name) { http.post(`${LEDGER}/mark?name=${name}`); }

export function incident() {
  mark('steady');
  http.post(`${ADMIN}/toxics`, JSON.stringify({ name: 'flaky', type: 'reset_peer', stream: 'upstream',
                                                toxicity: 0.05, attributes: { timeout: 0 } }), JSONH);
  sleep(8);
  http.del(`${ADMIN}/toxics/flaky`);
  http.post(`${ADMIN}/toxics`, JSON.stringify({ name: 'slow', type: 'latency', stream: 'downstream',
                                                attributes: { latency: 1500 } }), JSONH);
  mark('rush');
  sleep(10);
  http.post(`${ADMIN}/toxics/slow`, JSON.stringify({ attributes: { latency: 8000 } }), JSONH);
  mark('outage');
  sleep(10);
  http.del(`${ADMIN}/toxics/slow`);
  mark('after');
}

export function teardown() {
  const s = http.get(`${LEDGER}/stats`).json();
  retried404.add(s.repeated_after_404);
  outageCalls.add(s.received.outage);
}

export function handleSummary(d) {
  const lines = [];
  const kv = {};
  for (const [name, m] of Object.entries(d.metrics)) {
    if (!m.thresholds) continue;
    for (const [expr, res] of Object.entries(m.thresholds)) {
      lines.push(`  ${res.ok ? 'ok  ' : 'FAIL'}  ${name}  ${expr}`);
      kv[`fail.${name}`] = res.ok ? 0 : 1;
    }
  }
  const v = (m, k) => (d.metrics[m] && d.metrics[m].values[k] !== undefined ? d.metrics[m].values[k] : -1);
  kv.checkout_max_ms = Math.round(v('http_req_duration{route:checkout}', 'max'));
  kv.browse_p95_ms = Math.round(v('http_req_duration{route:browse}', 'p(95)'));
  kv.rush_sold = v('rush_sold', 'count');
  kv.retried_404 = v('retried_404', 'count');
  kv.outage_calls = v('outage_calls', 'value');
  for (const p of ['steady', 'rush', 'outage', 'after']) kv[`ok_${p}`] = v(`checks{phase:${p}}`, 'rate');
  lines.sort();
  const out = ['SLOs:'].concat(lines).concat(Object.entries(kv).map(([k, x]) => `kv ${k}=${x}`));
  return { stdout: out.join('\n') + '\n' };
}
