// 스파이크/스트레스 테스트: "선착순 쿠폰 발급" 상황을 그대로 흉내낸다 —
// 수천 명의 서로 다른 사용자가 정확히 한 번씩, 거의 동시에 발급을 시도한다.
// per-vu-iterations executor로 VU 수만큼 실사용자를 만들고 각자 1회만 요청하게 해서
// (반복 호출하는 폐쇄형 부하가 아니라) 진짜 "동시 집중 요청" 상황에 가깝게 만든다.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { createTestCoupon } from '../lib/helpers.js';
import { buildSummaryText } from '../lib/report.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';
// 비관적 락 자체(행 락)가 병목이라 재고를 수요보다 훨씬 크게 잡아도 락 경합은 그대로 재현된다.
// 재고 소진으로 인한 400을 같이 관찰하고 싶으면 SPIKE_VUS보다 작은 값으로 낮춰서 실행.
const COUPON_QUANTITY = Number(__ENV.COUPON_QUANTITY || 100000);
const SPIKE_VUS = Number(__ENV.SPIKE_VUS || 3000);
const SPIKE_MAX_DURATION = __ENV.SPIKE_MAX_DURATION || '3m';

const issued = new Counter('coupon_issued_total');
const soldOut = new Counter('coupon_sold_out_total');
const duplicate = new Counter('coupon_duplicate_total');
const unexpected = new Counter('coupon_unexpected_total');
const issueDuration = new Trend('coupon_issue_duration', true);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    spike: {
      executor: 'per-vu-iterations',
      exec: 'issue',
      vus: SPIKE_VUS,
      iterations: 1,
      maxDuration: SPIKE_MAX_DURATION,
    },
  },
};

export function setup() {
  const coupon = createTestCoupon(
    BASE_URL,
    COUPON_QUANTITY,
    `[k6-spike] ${new Date().toISOString()}`,
  );
  return { couponId: coupon.id };
}

export function issue(data) {
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
  const report = buildSummaryText('spike', data);
  const ts = Date.now();
  return {
    stdout: report,
    [`results/spike-${ts}.md`]: report,
    [`results/spike-${ts}.json`]: JSON.stringify(data, null, 2),
  };
}
