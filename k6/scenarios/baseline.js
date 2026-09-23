// 베이스라인 부하 테스트: 단일 파드/소규모 트래픽 상황에서 비관적 락 발급 API의
// "정상 상태" 성능(RPS, 지연시간, 에러율)을 측정한다. spike.js와 비교할 기준선.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { createTestCoupon } from '../lib/helpers.js';
import { buildSummaryText } from '../lib/report.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';
const COUPON_QUANTITY = Number(__ENV.COUPON_QUANTITY || 100000);

const issued = new Counter('coupon_issued_total');
const soldOut = new Counter('coupon_sold_out_total');
const duplicate = new Counter('coupon_duplicate_total');
const unexpected = new Counter('coupon_unexpected_total');
const issueDuration = new Trend('coupon_issue_duration', true);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    baseline: {
      executor: 'ramping-vus',
      exec: 'issue',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 10 }, // 워밍업
        { duration: '40s', target: 10 }, // 정상 상태 유지
        { duration: '10s', target: 0 }, // 쿨다운
      ],
    },
  },
};

export function setup() {
  const coupon = createTestCoupon(
    BASE_URL,
    COUPON_QUANTITY,
    `[k6-baseline] ${new Date().toISOString()}`,
  );
  return { couponId: coupon.id };
}

export function issue(data) {
  // 시나리오 전체에서 단조 증가하는 고유 카운터라 VU/반복 조합과 무관하게 userId가 겹치지 않는다.
  const userId = String(exec.scenario.iterationInTest + 1);

  const res = http.post(
    `${BASE_URL}/coupons/${data.couponId}/issue`,
    JSON.stringify({ userId }),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'issue_coupon' },
    },
  );

  issueDuration.add(res.timings.duration);
  check(res, {
    '예상된 응답 코드 (201/400/409)': (r) => [201, 400, 409].includes(r.status),
  });

  if (res.status === 201) issued.add(1);
  else if (res.status === 400) soldOut.add(1);
  else if (res.status === 409) duplicate.add(1);
  else unexpected.add(1);
}

export function handleSummary(data) {
  const report = buildSummaryText('baseline', data);
  const ts = Date.now();
  return {
    stdout: report,
    [`results/baseline-${ts}.md`]: report,
    [`results/baseline-${ts}.json`]: JSON.stringify(data, null, 2),
  };
}
