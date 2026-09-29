import { ConfigService } from '@nestjs/config';
import { Test, TestingModule } from '@nestjs/testing';
import { TypeOrmModule } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import {
  COUPON_EXCHANGE,
  COUPON_ISSUED_QUEUE,
  COUPON_ISSUED_ROUTING_KEY,
} from '../coupons/coupon-event-publisher.service';
import { COUPON_ISSUED_DLQ, RETRY_STAGES } from '../coupons/coupon-messaging.constants';
import { Coupon } from '../coupons/entities/coupon.entity';
import { CouponIssue } from '../coupons/entities/coupon-issue.entity';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';
import { connectTestChannel, TestChannel } from '../test-utils/rabbitmq-test-channel';
import { TEST_RETRY_TTL_MS } from '../test-utils/retry-ttl';
import { CouponIssueConsumerService } from './coupon-issue-consumer.service';
import { CouponRetryRouter } from './coupon-retry-router.service';

jest.setTimeout(30000);

const BATCH_SIZE = 5;
const FLUSH_INTERVAL_MS = 150;

async function waitUntil(
  condition: () => Promise<boolean>,
  timeoutMs = 5000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error('waitUntil 타임아웃');
}

describe('CouponIssueConsumerService (batch persistence integration)', () => {
  let moduleRef: TestingModule;
  let dataSource: DataSource;
  let publisherChannel: TestChannel;
  let consumerChannel: TestChannel;
  let couponId: string;

  beforeAll(async () => {
    publisherChannel = await connectTestChannel();

    moduleRef = await Test.createTestingModule({
      imports: [
        TypeOrmModule.forRoot({
          type: 'postgres',
          host: process.env.TEST_DB_HOST ?? 'localhost',
          port: Number(process.env.TEST_DB_PORT ?? 5433),
          username: process.env.DB_USERNAME ?? 'postgres',
          password: process.env.DB_PASSWORD ?? 'postgres',
          database: process.env.DB_DATABASE ?? 'rush_coupon',
          entities: [Coupon, CouponIssue],
          synchronize: false,
        }),
        TypeOrmModule.forFeature([CouponIssue]),
      ],
      providers: [
        CouponIssueConsumerService,
        CouponRetryRouter,
        { provide: RABBITMQ_CHANNEL, useFactory: connectTestChannel },
        {
          provide: ConfigService,
          useValue: {
            get: (key: string, def: unknown) => {
              switch (key) {
                case 'WORKER_BATCH_SIZE':
                  return BATCH_SIZE;
                case 'WORKER_BATCH_FLUSH_INTERVAL_MS':
                  return FLUSH_INTERVAL_MS;
                case 'RETRY_TTL_2S_MS':
                  return TEST_RETRY_TTL_MS[0];
                case 'RETRY_TTL_8S_MS':
                  return TEST_RETRY_TTL_MS[1];
                case 'RETRY_TTL_32S_MS':
                  return TEST_RETRY_TTL_MS[2];
                default:
                  return def;
              }
            },
          },
        },
      ],
    }).compile();

    dataSource = moduleRef.get(DataSource);
    consumerChannel = moduleRef.get(RABBITMQ_CHANNEL);
    await moduleRef.init(); // onModuleInit -> 토폴로지 선언 + consume 시작
  });

  beforeEach(async () => {
    await dataSource.query(
      'TRUNCATE TABLE coupon_issues, coupons RESTART IDENTITY CASCADE',
    );
    // 재시도/DLQ 큐도 비워야 한다 — 안 그러면 앞선 테스트가 남긴 메시지 때문에
    // "정확히 1건/0건" 같은 절대 개수 검증이 오염된다.
    await publisherChannel.purgeQueue(COUPON_ISSUED_QUEUE);
    await publisherChannel.purgeQueue(COUPON_ISSUED_DLQ);
    for (const stage of RETRY_STAGES) {
      await publisherChannel.purgeQueue(stage.queue);
    }

    const [row] = (await dataSource.query(
      `INSERT INTO coupons (title, total_quantity, start_at, end_at)
       VALUES ('worker test', 1000, now() - interval '1 hour', now() + interval '1 hour')
       RETURNING id`,
    )) as { id: string }[];
    couponId = row.id;
  });

  afterAll(async () => {
    // moduleRef.close()가 Nest 라이프사이클(onApplicationShutdown)로 DataSource를 이미 닫으므로
    // 여기서 dataSource.destroy()를 또 호출하면 "이미 닫힘" 에러가 나 뒤 정리 코드가 실행되지 않는다.
    await moduleRef.close();
    // channel.close()는 AMQP 채널만 닫고 TCP 연결은 남겨둔다 — 연결 자체를 닫아야
    // 프로세스가 열린 소켓 없이 정상 종료된다.
    await publisherChannel.rawConnection.close();
    await consumerChannel.rawConnection.close();
  });

  function publish(payload: unknown): void {
    publisherChannel.publish(
      COUPON_EXCHANGE,
      COUPON_ISSUED_ROUTING_KEY,
      Buffer.from(typeof payload === 'string' ? payload : JSON.stringify(payload)),
      { persistent: true, contentType: 'application/json' },
    );
  }

  async function issueCount(): Promise<number> {
    return (
      await dataSource
        .getRepository(CouponIssue)
        .count({ where: { couponId } })
    );
  }

  async function queueCount(queue: string): Promise<number> {
    const { messageCount } = await publisherChannel.checkQueue(queue);
    return messageCount;
  }

  it('배치 크기만큼 쌓이면 즉시 저장하고 ack한다', async () => {
    for (let i = 0; i < BATCH_SIZE; i++) {
      publish({ couponId, userId: `${i + 1}`, requestedAt: new Date().toISOString() });
    }

    await waitUntil(async () => (await issueCount()) === BATCH_SIZE);

    const { messageCount } = await publisherChannel.checkQueue(
      COUPON_ISSUED_QUEUE,
    );
    expect(messageCount).toBe(0);
  });

  it('배치 크기 미만이면 flush 타이머가 돌 때 저장한다', async () => {
    publish({ couponId, userId: '1', requestedAt: new Date().toISOString() });
    publish({ couponId, userId: '2', requestedAt: new Date().toISOString() });

    await waitUntil(async () => (await issueCount()) === 2);
  });

  it('재전달된 중복 메시지는 조용히 무시하고 큐에서도 정상 제거된다', async () => {
    publish({ couponId, userId: '1', requestedAt: new Date().toISOString() });
    await waitUntil(async () => (await issueCount()) === 1);

    // 같은 (couponId, userId) 재전달 시나리오
    publish({ couponId, userId: '1', requestedAt: new Date().toISOString() });

    await waitUntil(async () => {
      const { messageCount } = await publisherChannel.checkQueue(
        COUPON_ISSUED_QUEUE,
      );
      return messageCount === 0;
    });
    expect(await issueCount()).toBe(1);
  });

  it('잘못된 포맷의 메시지는 재시도 단계를 거치지 않고 바로 DLQ로 격리한다', async () => {
    publish('this is not valid json');
    publish({ couponId, userId: '2' }); // requestedAt 없는 메시지도 포맷 오류로 취급해 DLQ로 격리
    publish({ couponId, userId: '1', requestedAt: new Date().toISOString() });

    await waitUntil(async () => (await issueCount()) === 1);
    await waitUntil(async () => (await queueCount(COUPON_ISSUED_DLQ)) === 2);

    expect(await queueCount(COUPON_ISSUED_QUEUE)).toBe(0);
    for (const stage of RETRY_STAGES) {
      expect(await queueCount(stage.queue)).toBe(0);
    }
  });

  it('계속 실패하면 2s→8s→32s 단계를 모두 거쳐 최종 DLQ로 격리된다', async () => {
    // 존재하지 않는 couponId라 FK 제약으로 매번 배치 INSERT가 실패하도록 강제한다.
    publish({
      couponId: '999999999',
      userId: '1',
      requestedAt: new Date().toISOString(),
    });

    for (const stage of RETRY_STAGES) {
      await waitUntil(async () => (await queueCount(stage.queue)) === 1, 2000);
    }
    await waitUntil(async () => (await queueCount(COUPON_ISSUED_DLQ)) === 1, 2000);

    expect(await queueCount(COUPON_ISSUED_QUEUE)).toBe(0);
    for (const stage of RETRY_STAGES) {
      expect(await queueCount(stage.queue)).toBe(0);
    }
  });

  it('재시도 중 원인이 해결되면(쿠폰 생성) 다음 재시도에서 정상 저장되고 DLQ로 가지 않는다', async () => {
    const missingCouponId = '888888888';
    publish({
      couponId: missingCouponId,
      userId: '1',
      requestedAt: new Date().toISOString(),
    });

    // 1차 실패 -> 2s(테스트에서는 TEST_RETRY_TTL_MS[0]) 재시도 큐로 들어갈 때까지 대기
    await waitUntil(
      async () => (await queueCount(RETRY_STAGES[0].queue)) === 1,
      2000,
    );

    // 원인 해결: 재시도 만료 전에 해당 id로 쿠폰을 만들어준다
    await dataSource.query(
      `INSERT INTO coupons (id, title, total_quantity, start_at, end_at)
       VALUES ($1, 'recovered', 1000, now() - interval '1 hour', now() + interval '1 hour')`,
      [missingCouponId],
    );

    await waitUntil(async () => {
      const count = await dataSource
        .getRepository(CouponIssue)
        .count({ where: { couponId: missingCouponId } });
      return count === 1;
    });

    expect(await queueCount(COUPON_ISSUED_DLQ)).toBe(0);
    for (const stage of RETRY_STAGES) {
      expect(await queueCount(stage.queue)).toBe(0);
    }

    await dataSource.query('DELETE FROM coupon_issues WHERE coupon_id = $1', [
      missingCouponId,
    ]);
    await dataSource.query('DELETE FROM coupons WHERE id = $1', [
      missingCouponId,
    ]);
  });
});
