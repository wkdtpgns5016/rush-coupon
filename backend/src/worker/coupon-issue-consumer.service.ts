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
import { CouponRetryRouter } from './coupon-retry-router.service';

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
  private readonly retryTtlMs: readonly [number, number, number];

  constructor(
    @Inject(RABBITMQ_CHANNEL) private readonly channel: ConfirmChannel,
    @InjectRepository(CouponIssue)
    private readonly couponIssueRepo: Repository<CouponIssue>,
    private readonly retryRouter: CouponRetryRouter,
    configService: ConfigService,
  ) {
    // ConfigService.get<number>()은 타입 단언일 뿐 실제 변환은 안 해준다 — 환경변수는 항상
    // 문자열이라 Number()로 직접 변환한다(특히 retryTtlMs는 AMQP 큐 인자로 그대로 나가는데,
    // backend/worker가 서로 다른 타입으로 보내면 재선언 시 406(PRECONDITION_FAILED)이 난다).
    // prefetch를 배치 크기와 동일하게 맞춰서, 브로커가 이 컨슈머에게 한 번에 배치 크기만큼만
    // 미확인(unacked) 메시지를 내려주도록 한다 — pending 배열이 자연스럽게 그 이상 안 커진다.
    this.batchSize = Number(configService.get('WORKER_BATCH_SIZE', 50));
    this.flushIntervalMs = Number(
      configService.get('WORKER_BATCH_FLUSH_INTERVAL_MS', 500),
    );
    this.retryTtlMs = [
      Number(configService.get('RETRY_TTL_2S_MS', 2000)),
      Number(configService.get('RETRY_TTL_8S_MS', 8000)),
      Number(configService.get('RETRY_TTL_32S_MS', 32000)),
    ];
  }

  async onModuleInit(): Promise<void> {
    await declareCouponIssuedTopology(this.channel, {
      retryTtlMs: this.retryTtlMs,
    });
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
      // 파싱 자체가 안 되는 메시지는 몇 번을 재시도해도 결과가 같으므로 단계를 거치지 않고
      // 바로 DLQ로 보낸다.
      this.logger.error('잘못된 메시지 포맷 — 재시도 없이 DLQ로 격리');
      void this.retryRouter.sendToDlq(message);
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
        `배치 저장 실패 (${batch.length}건) — 메시지별 x-death 이력에 따라 재시도 단계/DLQ로 라우팅`,
        err instanceof Error ? err.stack : err,
      );
      // 배치 안 메시지들이 각자 다른 재시도 단계에 있을 수 있으므로(서로 다른 시점에 발행됨)
      // 일괄 nack이 아니라 메시지별로 x-death를 보고 개별 라우팅한다.
      for (const { message } of batch) {
        try {
          await this.retryRouter.routeToNextStage(message);
        } catch (routingErr) {
          // 라우팅 자체가 실패하면(브로커 장애 등) ack하지 않고 넘어간다 — 컨슈머가 재연결되면
          // RabbitMQ가 이 메시지를 다시 배달해줘서 유실되지 않는다.
          this.logger.error(
            '재시도 라우팅 실패 — 메시지는 unacked 상태로 남아 재배달됨',
            routingErr instanceof Error ? routingErr.stack : routingErr,
          );
        }
      }
    } finally {
      this.flushing = false;
      // 처리 중 이미 배치 크기만큼 다시 쌓였다면(고부하 상황) 타이머를 기다리지 않고 바로 이어서 처리한다.
      if (this.pending.length >= this.batchSize) {
        void this.flush();
      }
    }
  }
}
