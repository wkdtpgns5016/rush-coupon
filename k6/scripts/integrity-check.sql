-- Issue #48: Worker 강제 종료(kubectl delete pod --grace-period=0 --force) 시나리오 이후
-- 데이터 정합성 검증. RabbitMQ 재전달과 배치 INSERT의 .orIgnore()+uq_coupon_user 기반
-- 멱등성이 실제 장애 상황에서도 유실·중복 없이 작동했는지 확인한다.
--
-- 사용법: 부하(k6) + 강제 종료 시나리오가 다 끝나고 Worker가 큐를 완전히 배출한 뒤 실행.
--   psql ... -f k6/scripts/integrity-check.sql
--   (cleanup.sql로 테스트 데이터를 지우기 전에 반드시 먼저 실행할 것)
\set prefix '\'[k6-%\''

-- 1) 저장된 발급 건수 — k6가 리포트한 "접수 성공(202)" 건수와 정확히 같아야 한다.
--    이보다 적으면 유실(재전달 실패), 많으면 중복 저장(멱등성 실패)을 의미한다.
--    (coupons.issued_quantity 컬럼은 비동기 구조에서 아무도 갱신하지 않는 죽은 값이라 쓰지 않는다)
SELECT
  c.title,
  c.total_quantity,
  count(*) AS persisted_count,
  count(DISTINCT ci.user_id) AS distinct_users
FROM coupon_issues ci
JOIN coupons c ON c.id = ci.coupon_id
WHERE c.title LIKE :prefix
GROUP BY c.title, c.total_quantity
ORDER BY c.title;

-- 2) 중복 발급 여부 — 정상이라면 0행이 나와야 한다.
--    uq_coupon_user 제약상 DB 레벨에서 원천적으로 불가능해야 하지만, 장애 시나리오
--    검증이니 명시적으로 다시 확인한다. 1행이라도 나오면 심각한 버그다.
SELECT
  c.title,
  ci.coupon_id,
  ci.user_id,
  count(*) AS dup_count
FROM coupon_issues ci
JOIN coupons c ON c.id = ci.coupon_id
WHERE c.title LIKE :prefix
GROUP BY c.title, ci.coupon_id, ci.user_id
HAVING count(*) > 1;

-- 3) 초과 발급 여부 — 저장 건수가 재고(total_quantity)를 넘으면 안 된다. 0행이 정상.
SELECT
  c.title,
  c.total_quantity,
  count(*) AS persisted_count
FROM coupon_issues ci
JOIN coupons c ON c.id = ci.coupon_id
WHERE c.title LIKE :prefix
GROUP BY c.title, c.total_quantity
HAVING count(*) > c.total_quantity;
