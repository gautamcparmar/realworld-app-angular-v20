import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = (__ENV.BASE_URL || '').replace(/\/$/, '');
const VUS = Number(__ENV.PERF_VUS || 8);
const P95_MS = Number(__ENV.PERF_P95_MS || 2000);
const P99_MS = Number(__ENV.PERF_P99_MS || 5000);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    mixed: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '20s', target: VUS },
        { duration: '40s', target: VUS },
        { duration: '10s', target: 0 },
      ],
    },
  },
  thresholds: {
    checks: ['rate>0.95'],
    http_req_failed: ['rate<0.05'],
    http_req_duration: [`p(95)<${P95_MS}`, `p(99)<${P99_MS}`],
  },
};

export function setup() {
  if (!BASE_URL) {
    throw new Error('BASE_URL is required');
  }

  const res = http.get(`${BASE_URL}/`);
  const ok = check(res, {
    'setup home 200': (r) => r.status === 200,
  });
  if (!ok) {
    throw new Error(`setup home failed: ${res.status} ${res.body}`);
  }
}

export default function () {
  const roll = Math.random();

  if (roll < 0.5) {
    const res = http.get(`${BASE_URL}/`);
    check(res, { 'home 200': (r) => r.status === 200 });
  } else if (roll < 0.75) {
    const res = http.get(`${BASE_URL}/login`);
    check(res, { 'login 200': (r) => r.status === 200 });
  } else if (roll < 0.9) {
    const res = http.get(`${BASE_URL}/register`);
    check(res, { 'register 200': (r) => r.status === 200 });
  } else {
    const res = http.get(`${BASE_URL}/api/tags`);
    check(res, { 'tags 200': (r) => r.status === 200 });
  }

  sleep(1);
}
