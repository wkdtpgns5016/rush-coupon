import { ConfigService } from '@nestjs/config';
import { Test, TestingModule } from '@nestjs/testing';
import { TypeOrmModule } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import {
  COUPON_EXCHANGE,
  COUPON_ISSUED_QUEUE,
  COUPON_ISSUED_ROUTING_KEY,
} from '../coupons/coupon-event-publisher.service';
import { Coupon } from '../coupons/entities/coupon.entity';
import { CouponIssue } from '../coupons/entities/coupon-issue.entity';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';
import { connectTestChannel, TestChannel } from '../test-utils/rabbitmq-test-channel';
import { CouponIssueConsumerService } from './coupon-issue-consumer.service';

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
        { provide: RABBITMQ_CHANNEL, useFactory: connectTestChannel },
        {
          provide: ConfigService,
          useValue: {
            get: (key: string, def: unknown) =>
              key === 'WORKER_BATCH_SIZE'
                ? BATCH_SIZE
                : key === 'WORKER_BATCH_FLUSH_INTERVAL_MS'
                  ? FLUSH_INTERVAL_MS
                  : def,
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
    await publisherChannel.purgeQueue(COUPON_ISSUED_QUEUE);

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

  it('잘못된 포맷의 메시지는 폐기하고 이후 정상 메시지 처리를 막지 않는다', async () => {
    publish('this is not valid json');
    publish({ couponId, userId: '1' }); // requestedAt 없어도 처리 대상(couponId/userId만 검증)

    await waitUntil(async () => (await issueCount()) === 1);

    const { messageCount } = await publisherChannel.checkQueue(
      COUPON_ISSUED_QUEUE,
    );
    expect(messageCount).toBe(0);
  });
});
