export const COUPON_EXCHANGE = 'coupon.exchange';
export const COUPON_ISSUED_QUEUE = 'coupon.issued';
export const COUPON_ISSUED_ROUTING_KEY = 'coupon.issued';

export const COUPON_RETRY_EXCHANGE = 'coupon.retry.exchange';
export const COUPON_ISSUED_DLQ = 'coupon.issued.dlq';
export const DLQ_ROUTING_KEY = 'dlq';

export interface RetryStage {
  queue: string;
  routingKey: string;
}

// 순서가 곧 단계 순서다(2s -> 8s -> 32s). 큐 이름은 운영 환경 기준 지연 시간을 그대로 딴 라벨이고,
// 실제 TTL 값은 declareCouponIssuedTopology의 retryTtlMs로 주입되므로 테스트에서는 훨씬 짧게 줄 수 있다.
export const RETRY_STAGES: readonly RetryStage[] = [
  { queue: 'coupon.retry.2s', routingKey: '2s' },
  { queue: 'coupon.retry.8s', routingKey: '8s' },
  { queue: 'coupon.retry.32s', routingKey: '32s' },
];

export interface CouponIssuedMessage {
  couponId: string;
  userId: string;
  requestedAt: string;
}
