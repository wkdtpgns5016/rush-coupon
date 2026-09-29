import { Inject, Injectable } from '@nestjs/common';
import type { ConfirmChannel, ConsumeMessage } from 'amqplib';
import {
  COUPON_RETRY_EXCHANGE,
  DLQ_ROUTING_KEY,
  RETRY_STAGES,
} from '../coupons/coupon-messaging.constants';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';

interface XDeathEntry {
  queue: string;
  reason: string;
  count: number;
}

// RabbitMQ는 재시도 큐가 TTL로 메시지를 coupon.issued에 돌려보낼 때마다 x-death 헤더에
// {queue: 그 재시도 큐 이름, reason: 'expired', ...} 항목을 자동으로 남긴다.
// 즉 이 메시지가 어느 재시도 큐까지 거쳐왔는지가 그대로 재시도 횟수 기록이 된다 — 그걸 보고
// 다음에 어디로 보낼지(다음 단계 큐, 혹은 전부 거쳤으면 DLQ)를 결정한다.
export function determineNextRoutingKey(message: ConsumeMessage): string {
  const xDeath =
    (message.properties.headers?.['x-death'] as XDeathEntry[] | undefined) ??
    [];
  const visitedQueues = new Set(xDeath.map((entry) => entry.queue));

  for (let i = RETRY_STAGES.length - 1; i >= 0; i--) {
    if (visitedQueues.has(RETRY_STAGES[i].queue)) {
      return RETRY_STAGES[i + 1]?.routingKey ?? DLQ_ROUTING_KEY;
    }
  }
  return RETRY_STAGES[0].routingKey;
}

@Injectable()
export class CouponRetryRouter {
  constructor(
    @Inject(RABBITMQ_CHANNEL) private readonly channel: ConfirmChannel,
  ) {}

  // 정상 처리 실패(배치 저장 실패 등) — x-death 이력을 보고 다음 재시도 단계 혹은 DLQ로 보낸다.
  async routeToNextStage(message: ConsumeMessage): Promise<void> {
    await this.publish(determineNextRoutingKey(message), message);
    this.channel.ack(message);
  }

  // 파싱 자체가 불가능한 메시지 — 몇 번을 재시도해도 결과가 같으므로 단계를 거치지 않고 바로 DLQ로 보낸다.
  async sendToDlq(message: ConsumeMessage): Promise<void> {
    await this.publish(DLQ_ROUTING_KEY, message);
    this.channel.ack(message);
  }

  // 재시도/DLQ 큐로 발행이 브로커에 확실히 안착한 뒤에만 원본을 ack해야 유실이 없다.
  private publish(routingKey: string, message: ConsumeMessage): Promise<void> {
    return new Promise((resolve, reject) => {
      this.channel.publish(
        COUPON_RETRY_EXCHANGE,
        routingKey,
        message.content,
        {
          persistent: true,
          contentType: message.properties.contentType,
          headers: message.properties.headers,
        },
        (err) => (err ? reject(err) : resolve()),
      );
    });
  }
}
