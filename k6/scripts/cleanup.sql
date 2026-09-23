-- k6 부하 테스트가 setup()에서 만든 테스트 전용 쿠폰(제목이 "[k6-"로 시작)과
-- 그 쿠폰들에 딸린 발급 이력을 정리한다. API에 DELETE 엔드포인트가 없어 psql로 직접 실행한다.
-- coupon_issues -> coupons 순서로 지워야 fk_coupon_issues_coupon(ON DELETE RESTRICT) 제약을 만족한다.
BEGIN;

DELETE FROM coupon_issues
WHERE coupon_id IN (
  SELECT id FROM coupons WHERE title LIKE '[k6-%'
);

DELETE FROM coupons WHERE title LIKE '[k6-%';

COMMIT;
