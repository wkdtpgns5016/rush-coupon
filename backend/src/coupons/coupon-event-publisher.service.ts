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

@Injectable()
export class CouponEventPublisher implements OnModuleInit {
  constructor(
    @Inject(RABBITMQ_CHANNEL) private readonly channel: ConfirmChannel,
  ) {}

  async onModuleInit(): Promise<void> {
    await this.channel.assertExchange(COUPON_EXCHANGE, 'direct', {
      durable: true,
    });
    await this.channel.assertQueue(COUPON_ISSUED_QUEUE, { durable: true });
    await this.channel.bindQueue(
      COUPON_ISSUED_QUEUE,
      COUPON_EXCHANGE,
      COUPON_ISSUED_ROUTING_KEY,
    );
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
