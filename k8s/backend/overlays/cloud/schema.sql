-- rush-coupon: 쿠폰 도메인 스키마 (DDL)
-- Issue #4: 쿠폰 도메인 모델링 및 PostgreSQL 스키마 정의
--
-- =========================================
-- 1. coupons (쿠폰 마스터)
-- =========================================
CREATE TABLE IF NOT EXISTS coupons (
    id               BIGSERIAL PRIMARY KEY,
    title            VARCHAR(100) NOT NULL,
    total_quantity   INT NOT NULL,
    issued_quantity  INT NOT NULL DEFAULT 0,
    start_at         TIMESTAMP WITH TIME ZONE NOT NULL,
    end_at           TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_coupon_quantity CHECK (issued_quantity <= total_quantity),
    CONSTRAINT chk_coupon_issued_positive CHECK (issued_quantity >= 0),
    CONSTRAINT chk_coupon_period CHECK (end_at > start_at)
);

-- =========================================
-- 2. coupon_issues (쿠폰 발급 이력)
-- =========================================
CREATE TABLE IF NOT EXISTS coupon_issues (
    id           BIGSERIAL PRIMARY KEY,
    coupon_id    BIGINT NOT NULL,
    user_id      BIGINT NOT NULL,
    requested_at TIMESTAMP WITH TIME ZONE,
    issued_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_coupon_issues_coupon
        FOREIGN KEY (coupon_id) REFERENCES coupons(id) ON DELETE RESTRICT,
    CONSTRAINT uq_coupon_user UNIQUE (coupon_id, user_id)
);

-- Issue #47: 이미 배포된 환경(테이블이 CREATE TABLE IF NOT EXISTS를 건너뛰는 경우)에도
-- 종단 지연(큐 적재→Worker 저장) 계산용 컬럼이 반영되도록 재실행 가능한 ALTER를 둔다.
ALTER TABLE coupon_issues ADD COLUMN IF NOT EXISTS requested_at TIMESTAMP WITH TIME ZONE;

-- =========================================
-- 3. 인덱스
-- =========================================
CREATE INDEX IF NOT EXISTS idx_coupon_issues_user ON coupon_issues(user_id);
