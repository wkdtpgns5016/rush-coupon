// k6 handleSummary()에서 쓰는 공통 리포트 포맷터.
// RPS/지연시간/발급 결과 분포(성공·재고소진·중복·기타)를 사람이 읽을 수 있는 표로 정리한다.
export function buildSummaryText(scenarioName, data) {
  const m = data.metrics;
  const totalRequests = m.http_reqs ? m.http_reqs.values.count : 0;
  const rps = m.http_reqs ? m.http_reqs.values.rate : 0;
  const dur = m.http_req_duration ? m.http_req_duration.values : {};
  const httpFailedRate = m.http_req_failed ? m.http_req_failed.values.rate : 0;

  const issued = m.coupon_issued_total ? m.coupon_issued_total.values.count : 0;
  const soldOut = m.coupon_sold_out_total ? m.coupon_sold_out_total.values.count : 0;
  const duplicate = m.coupon_duplicate_total
    ? m.coupon_duplicate_total.values.count
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
    `- 지연 시간: avg=${ms(dur.avg)}ms / p95=${ms(dur['p(95)'])}ms / p99=${ms(dur['p(99)'])}ms / max=${ms(dur.max)}ms`,
    `- 네트워크 레벨 실패율 (http_req_failed): ${(httpFailedRate * 100).toFixed(2)}%`,
    '',
    '## 발급 결과 분포',
    '',
    '| 결과 | 건수 | 비율 |',
    '|---|---|---|',
    `| 발급 성공 (201) | ${issued} | ${pct(issued)}% |`,
    `| 재고 소진/기간 아님 (400) | ${soldOut} | ${pct(soldOut)}% |`,
    `| 중복 발급 (409) | ${duplicate} | ${pct(duplicate)}% |`,
    `| 예상치 못한 응답 | ${unexpected} | ${pct(unexpected)}% |`,
    '',
  ].join('\n');
}
