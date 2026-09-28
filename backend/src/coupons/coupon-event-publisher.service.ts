import { Inject, Injectable, OnModuleInit } from '@nestjs/common';
import type { ConfirmChannel } from 'amqplib';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';

export const COUPON_EXCHANGE = 'coupon.exchange';
export const COUPON_ISSUED_QUEUE = 'coupon.issued';
export const COUPON_ISSUED_ROUTING_KEY = 'coupon.issued';

export interface CouponIssuedMessage {
  couponId: string;
  userId: string;
  requestedAt: string;
}

// backend(발행)와 worker(구독)는 서로 다른 Nest 애플리케이션이라, 둘 중 무엇이 먼저 떠도
// 토폴로지가 준비되도록 양쪽 onModuleInit에서 이 선언을 그대로 재사용한다.
export async function declareCouponIssuedTopology(
  channel: ConfirmChannel,
): Promise<void> {
  await channel.assertExchange(COUPON_EXCHANGE, 'direct', { durable: true });
  await channel.assertQueue(COUPON_ISSUED_QUEUE, { durable: true });
  await channel.bindQueue(
    COUPON_ISSUED_QUEUE,
    COUPON_EXCHANGE,
    COUPON_ISSUED_ROUTING_KEY,
  );
}

@Injectable()
export class CouponEventPublisher implements OnModuleInit {
  constructor(
    @Inject(RABBITMQ_CHANNEL) private readonly channel: ConfirmChannel,
  ) {}

  async onModuleInit(): Promise<void> {
    await declareCouponIssuedTopology(this.channel);
  }

  publishCouponIssued(message: CouponIssuedMessage): Promise<void> {
    return new Promise((resolve, reject) => {
      const content = Buffer.from(JSON.stringify(message));
      this.channel.publish(
        COUPON_EXCHANGE,
        COUPON_ISSUED_ROUTING_KEY,
        content,
        { persistent: true, contentType: 'application/json' },
        (err) => (err ? reject(err) : resolve()),
      );
    });
  }
}
