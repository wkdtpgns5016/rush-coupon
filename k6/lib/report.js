// k6 handleSummary()에서 쓰는 공통 리포트 포맷터.
// RPS/지연시간/발급 결과 분포(접수·재고소진·중복·기타)를 사람이 읽을 수 있는 표로 정리한다.
// M5(#47)부터 이 리포트가 재는 지연은 "API 응답 지연"(202 접수까지)뿐이다 — 실제 DB 반영까지의
// 종단 지연은 k6/scripts/latency-report.sql로 테스트 종료 후 별도 계산해 이 리포트와 나란히 본다.
export function buildSummaryText(scenarioName, data) {
  const m = data.metrics;
  const totalRequests = m.http_reqs ? m.http_reqs.values.count : 0;
  const rps = m.http_reqs ? m.http_reqs.values.rate : 0;
  const dur = m.http_req_duration ? m.http_req_duration.values : {};
  const httpFailedRate = m.http_req_failed ? m.http_req_failed.values.rate : 0;

  const accepted = m.coupon_accepted_total
    ? m.coupon_accepted_total.values.count
    : 0;
  const soldOut = m.coupon_sold_out_total ? m.coupon_sold_out_total.values.count : 0;
  const notFound = m.coupon_not_found_total
    ? m.coupon_not_found_total.values.count
    : 0;
  const duplicate = m.coupon_duplicate_total
    ? m.coupon_duplicate_total.values.count
    : 0;
  const unavailable = m.coupon_unavailable_total
    ? m.coupon_unavailable_total.values.count
    : 0;
  const unexpected = m.coupon_unexpected_total
    ? m.coupon_unexpected_total.values.count
    : 0;

  const pct = (n) =>
    totalRequests ? ((n / totalRequests) * 100).toFixed(2) : '0.00';
  const ms = (v) => (typeof v === 'number' ? v.toFixed(1) : 'N/A');

  return [
    `# k6 결과 — ${scenarioName}`,
    '',
    `- 실행 시각: ${new Date().toISOString()}`,
    `- 총 요청 수: ${totalRequests}`,
    `- RPS (평균): ${rps.toFixed(2)}`,
    `- API 응답 지연: avg=${ms(dur.avg)}ms / p95=${ms(dur['p(95)'])}ms / p99=${ms(dur['p(99)'])}ms / max=${ms(dur.max)}ms`,
    `- 네트워크 레벨 실패율 (http_req_failed): ${(httpFailedRate * 100).toFixed(2)}%`,
    '',
    '## 발급 요청 결과 분포',
    '',
    '| 결과 | 건수 | 비율 |',
    '|---|---|---|',
    `| 접수 성공 (202) | ${accepted} | ${pct(accepted)}% |`,
    `| 재고 소진/기간 아님 (400) | ${soldOut} | ${pct(soldOut)}% |`,
    `| 쿠폰 없음 (404) | ${notFound} | ${pct(notFound)}% |`,
    `| 중복 발급 (409) | ${duplicate} | ${pct(duplicate)}% |`,
    `| 발급 처리 실패 (503) | ${unavailable} | ${pct(unavailable)}% |`,
    `| 예상치 못한 응답 | ${unexpected} | ${pct(unexpected)}% |`,
    '',
    '> 종단 지연(큐 적재→Worker 저장 완료)은 이 리포트에 없다 — `k6/scripts/latency-report.sql`로 별도 계산.',
    '',
  ].join('\n');
}
