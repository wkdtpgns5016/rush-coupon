import { Inject, Injectable, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { ConfirmChannel } from 'amqplib';
import {
  COUPON_EXCHANGE,
  COUPON_ISSUED_DLQ,
  COUPON_ISSUED_QUEUE,
  COUPON_ISSUED_ROUTING_KEY,
  COUPON_RETRY_EXCHANGE,
  CouponIssuedMessage,
  DLQ_ROUTING_KEY,
  RETRY_STAGES,
} from './coupon-messaging.constants';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';

export { COUPON_EXCHANGE, COUPON_ISSUED_QUEUE, COUPON_ISSUED_ROUTING_KEY };
export type { CouponIssuedMessage };

export interface RetryTtlConfig {
  retryTtlMs: readonly [number, number, number];
}

// backend(발행)와 worker(구독/재시도 라우팅)는 서로 다른 Nest 애플리케이션이라, 둘 중 무엇이
// 먼저 떠도 토폴로지가 준비되도록 양쪽 onModuleInit에서 이 선언을 그대로 재사용한다.
export async function declareCouponIssuedTopology(
  channel: ConfirmChannel,
  { retryTtlMs }: RetryTtlConfig,
): Promise<void> {
  await channel.assertExchange(COUPON_EXCHANGE, 'direct', { durable: true });
  await channel.assertExchange(COUPON_RETRY_EXCHANGE, 'direct', {
    durable: true,
  });

  await channel.assertQueue(COUPON_ISSUED_QUEUE, { durable: true });
  await channel.bindQueue(
    COUPON_ISSUED_QUEUE,
    COUPON_EXCHANGE,
    COUPON_ISSUED_ROUTING_KEY,
  );

  // 재시도 큐는 컨슈머가 없는 "대기실"이다 — TTL 만료 시 자체 DLX로 coupon.issued에 되돌아가
  // Worker가 다시 처리를 시도한다. 몇 단계까지 거쳤는지는 이때 RabbitMQ가 자동으로 남기는
  // x-death 헤더로 판단한다(CouponRetryRouter 참고).
  for (const [i, stage] of RETRY_STAGES.entries()) {
    await channel.assertQueue(stage.queue, {
      durable: true,
      arguments: {
        'x-message-ttl': retryTtlMs[i],
        'x-dead-letter-exchange': COUPON_EXCHANGE,
        'x-dead-letter-routing-key': COUPON_ISSUED_ROUTING_KEY,
      },
    });
    await channel.bindQueue(stage.queue, COUPON_RETRY_EXCHANGE, stage.routingKey);
  }

  await channel.assertQueue(COUPON_ISSUED_DLQ, { durable: true });
  await channel.bindQueue(COUPON_ISSUED_DLQ, COUPON_RETRY_EXCHANGE, DLQ_ROUTING_KEY);
}

@Injectable()
export class CouponEventPublisher implements OnModuleInit {
  constructor(
    @Inject(RABBITMQ_CHANNEL) private readonly channel: ConfirmChannel,
    private readonly configService: ConfigService,
  ) {}

  async onModuleInit(): Promise<void> {
    await declareCouponIssuedTopology(this.channel, {
      // ConfigService.get<number>()은 타입 단언일 뿐 실제 변환은 안 해준다 — 환경변수는 항상
      // 문자열이라 Number()로 직접 변환하지 않으면 AMQP 인자 타입이 backend/worker 사이에서
      // 어긋나 큐 재선언 시 406(PRECONDITION_FAILED)이 난다.
      retryTtlMs: [
        Number(this.configService.get('RETRY_TTL_2S_MS', 2000)),
        Number(this.configService.get('RETRY_TTL_8S_MS', 8000)),
        Number(this.configService.get('RETRY_TTL_32S_MS', 32000)),
      ],
    });
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
