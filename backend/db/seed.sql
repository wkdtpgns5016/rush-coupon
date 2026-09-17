-- rush-coupon: 로컬 개발용 시드 데이터
-- docker-entrypoint-initdb.d에서 schema.sql 다음 순서로 실행됨 (최초 초기화 시 1회만 적용)
INSERT INTO coupons (title, total_quantity, issued_quantity, start_at, end_at)
VALUES ('선착순 테스트 쿠폰', 10, 0, now() - interval '1 day', now() + interval '30 days');
