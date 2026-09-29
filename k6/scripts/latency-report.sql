-- Issue #47: 종단 지연(큐 적재 → Worker 배치 저장 완료) 계산.
-- API 응답(202)은 Valkey 판정 통과 시점에만 나가고 실제 DB 반영 여부/시각을 알려주지 않으므로,
-- k6는 "API 응답 지연"만 잴 수 있다. 이 스크립트는 테스트 종료 후 DB에 남은
-- coupon_issues.requested_at(RabbitMQ 발행 시각) ~ issued_at(배치 INSERT 완료 시각)의 차이로
-- 종단 지연 분포를 계산한다 — k6 리포트(API 응답 지연)와 나란히 놓고 비교한다.
--
-- 사용법:
--   psql ... -f k6/scripts/latency-report.sql
--   (특정 시나리오만 보고 싶으면 psql -v prefix="'[k6-spike%'" -f latency-report.sql)
\set prefix '\'[k6-%\''

SELECT
  c.title,
  count(*) AS persisted_count,
  count(*) FILTER (WHERE ci.requested_at IS NULL) AS missing_requested_at,
  round(avg(extract(epoch FROM (ci.issued_at - ci.requested_at)) * 1000)::numeric, 1) AS avg_ms,
  round(
    percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM (ci.issued_at - ci.requested_at)) * 1000)::numeric,
    1
  ) AS p50_ms,
  round(
    percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch FROM (ci.issued_at - ci.requested_at)) * 1000)::numeric,
    1
  ) AS p95_ms,
  round(
    percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM (ci.issued_at - ci.requested_at)) * 1000)::numeric,
    1
  ) AS p99_ms,
  round((max(extract(epoch FROM (ci.issued_at - ci.requested_at))) * 1000)::numeric, 1) AS max_ms
FROM coupon_issues ci
JOIN coupons c ON c.id = ci.coupon_id
WHERE c.title LIKE :prefix
GROUP BY c.title
ORDER BY c.title;
