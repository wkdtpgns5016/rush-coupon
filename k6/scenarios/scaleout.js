// #32용 — 파드 스케일아웃(HPA 확장) 환경에서 성능 변화를 관찰하기 위한 시나리오.
// baseline/spike와 executor를 다르게 가져간 이유:
//   - spike.js(per-vu-iterations)는 부하가 시작 시점에 한꺼번에 몰렸다가 바로 빠져서,
//     HPA가 CPU를 보고 2→3→5→...→10으로 여러 단계를 거칠 시간이 없다.
//   - 그래서 여기서는 ramping-arrival-rate로 "초당 요청 수"를 몇 분간 일정하게 유지한다.
//     #31에서 확인한 커밋 TPS 상한(~30 ops/s)보다 높은 요청률을 목표로 잡아서,
//     락 경합이 실제 병목이라면 파드가 아무리 늘어나도 처리량이 그 상한 근처에 눌려 있는지,
//     아니면 파드 수 증가에 따라 실제로 뚫리는지를 몇 분 단위로 Grafana(HPA/오토스케일링,
//     postgres-exporter 락 대기/커넥션)와 대조해서 확인한다.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { createTestCoupon } from '../lib/helpers.js';
import { buildSummaryText } from '../lib/report.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';
const COUPON_QUANTITY = Number(__ENV.COUPON_QUANTITY || 1000000);

// #31 baseline/spike에서 관찰된 커밋 TPS 상한(~30 ops/s)보다 의도적으로 높게 잡은 목표 요청률.
const TARGET_RATE = Number(__ENV.SCALEOUT_RATE || 60);
const RAMP_DURATION = __ENV.SCALEOUT_RAMP_DURATION || '2m';
const HOLD_DURATION = __ENV.SCALEOUT_HOLD_DURATION || '8m';
const RAMP_DOWN_DURATION = __ENV.SCALEOUT_RAMP_DOWN_DURATION || '1m';
const PRE_ALLOCATED_VUS = Number(__ENV.SCALEOUT_PRE_VUS || 300);
const MAX_VUS = Number(__ENV.SCALEOUT_MAX_VUS || 2000);

const issued = new Counter('coupon_issued_total');
const soldOut = new Counter('coupon_sold_out_total');
const duplicate = new Counter('coupon_duplicate_total');
const unexpected = new Counter('coupon_unexpected_total');
const issueDuration = new Trend('coupon_issue_duration', true);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    scaleout: {
      executor: 'ramping-arrival-rate',
      exec: 'issue',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
      stages: [
        { target: TARGET_RATE, duration: RAMP_DURATION },
        { target: TARGET_RATE, duration: HOLD_DURATION },
        { target: 0, duration: RAMP_DOWN_DURATION },
      ],
    },
  },
};

export function setup() {
  const coupon = createTestCoupon(
    BASE_URL,
    COUPON_QUANTITY,
    `[k6-scaleout] ${new Date().toISOString()}`,
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
  const report = buildSummaryText('scaleout', data);
  const ts = Date.now();
  return {
    stdout: report,
    [`results/scaleout-${ts}.md`]: report,
    [`results/scaleout-${ts}.json`]: JSON.stringify(data, null, 2),
  };
}
