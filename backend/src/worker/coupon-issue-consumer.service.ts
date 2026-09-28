import { Inject, Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectRepository } from '@nestjs/typeorm';
import type { ConfirmChannel, ConsumeMessage } from 'amqplib';
import { Repository } from 'typeorm';
import {
  COUPON_ISSUED_QUEUE,
  CouponIssuedMessage,
  declareCouponIssuedTopology,
} from '../coupons/coupon-event-publisher.service';
import { CouponIssue } from '../coupons/entities/coupon-issue.entity';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';

interface PendingItem {
  message: ConsumeMessage;
  payload: CouponIssuedMessage;
}

@Injectable()
export class CouponIssueConsumerService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(CouponIssueConsumerService.name);
  private readonly batchSize: number;
  private readonly flushIntervalMs: number;
  private pending: PendingItem[] = [];
  private flushing = false;
  private flushTimer?: NodeJS.Timeout;
  private consumerTag?: string;

  constructor(
    @Inject(RABBITMQ_CHANNEL) private readonly channel: ConfirmChannel,
    @InjectRepository(CouponIssue)
    private readonly couponIssueRepo: Repository<CouponIssue>,
    configService: ConfigService,
  ) {
    // prefetch를 배치 크기와 동일하게 맞춰서, 브로커가 이 컨슈머에게 한 번에 배치 크기만큼만
    // 미확인(unacked) 메시지를 내려주도록 한다 — pending 배열이 자연스럽게 그 이상 안 커진다.
    this.batchSize = configService.get<number>('WORKER_BATCH_SIZE', 50);
    this.flushIntervalMs = configService.get<number>(
      'WORKER_BATCH_FLUSH_INTERVAL_MS',
      500,
    );
  }

  async onModuleInit(): Promise<void> {
    await declareCouponIssuedTopology(this.channel);
    await this.channel.prefetch(this.batchSize);

    const { consumerTag } = await this.channel.consume(
      COUPON_ISSUED_QUEUE,
      (message) => this.onMessage(message),
      { noAck: false },
    );
    this.consumerTag = consumerTag;

    // 트래픽이 뜸해서 배치가 batchSize까지 안 차는 경우를 위한 최대 대기 시간 기반 flush.
    this.flushTimer = setInterval(() => void this.flush(), this.flushIntervalMs);
  }

  async onModuleDestroy(): Promise<void> {
    if (this.flushTimer) clearInterval(this.flushTimer);
    if (this.consumerTag) await this.channel.cancel(this.consumerTag);
    await this.flush();
  }

  private onMessage(message: ConsumeMessage | null): void {
    if (!message) return; // 컨슈머가 취소될 때 amqplib이 null을 전달한다

    const payload = this.parsePayload(message);
    if (!payload) {
      this.logger.error('잘못된 메시지 포맷 — 폐기 (재시도/DLQ 라우팅은 별도 이슈에서 구성)');
      this.channel.nack(message, false, false);
      return;
    }

    this.pending.push({ message, payload });
    if (this.pending.length >= this.batchSize) {
      void this.flush();
    }
  }

  private parsePayload(message: ConsumeMessage): CouponIssuedMessage | null {
    try {
      const parsed: unknown = JSON.parse(message.content.toString('utf-8'));
      const { couponId, userId } = parsed as Partial<CouponIssuedMessage>;
      if (typeof couponId !== 'string' || typeof userId !== 'string') {
        return null;
      }
      return parsed as CouponIssuedMessage;
    } catch {
      return null;
    }
  }

  private async flush(): Promise<void> {
    if (this.flushing || this.pending.length === 0) return;
    this.flushing = true;

    const batch = this.pending;
    this.pending = [];
    const lastMessage = batch[batch.length - 1].message;

    try {
      await this.couponIssueRepo
        .createQueryBuilder()
        .insert()
        .into(CouponIssue)
        .values(
          batch.map(({ payload }) => ({
            couponId: payload.couponId,
            userId: payload.userId,
          })),
        )
        // at-least-once 전달이라, INSERT는 성공했는데 ack 직전에 워커가 죽으면 같은 메시지가
        // 재전달되어 동일한 (coupon_id, user_id)가 다시 들어올 수 있다. 이미 반영된 발급을
        // 실패로 취급해 불필요한 재시도 루프를 만들지 않도록 조용히 무시한다.
        .orIgnore()
        .execute();

      this.channel.ack(lastMessage, true);
      this.logger.log(`${batch.length}건 배치 저장 완료`);
    } catch (err) {
      this.logger.error(
        `배치 저장 실패 (${batch.length}건) — 재시도/DLQ 라우팅은 별도 이슈에서 구성 예정, 우선 폐기`,
        err instanceof Error ? err.stack : err,
      );
      this.channel.nack(lastMessage, true, false);
    } finally {
      this.flushing = false;
      // 처리 중 이미 배치 크기만큼 다시 쌓였다면(고부하 상황) 타이머를 기다리지 않고 바로 이어서 처리한다.
      if (this.pending.length >= this.batchSize) {
        void this.flush();
      }
    }
  }
}
