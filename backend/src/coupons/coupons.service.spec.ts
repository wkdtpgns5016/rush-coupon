import {
  BadRequestException,
  ConflictException,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { Test, TestingModule } from '@nestjs/testing';
import { TypeOrmModule, getRepositoryToken } from '@nestjs/typeorm';
import type { ConfirmChannel } from 'amqplib';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';
import {
  COUPON_ISSUED_QUEUE,
  CouponEventPublisher,
} from './coupon-event-publisher.service';
import { CouponStockService } from './coupon-stock.service';
import { CouponsService } from './coupons.service';
import { Coupon } from './entities/coupon.entity';
import { CouponIssue } from './entities/coupon-issue.entity';
import { RABBITMQ_CHANNEL } from '../rabbitmq/rabbitmq.constants';
import { connectTestChannel, TestChannel } from '../test-utils/rabbitmq-test-channel';
import { TEST_RETRY_TTL_MS } from '../test-utils/retry-ttl';
import { VALKEY_CLIENT } from '../valkey/valkey.constants';

jest.setTimeout(30000);

// 이 스펙은 재시도 자체를 테스트하지 않지만, CouponEventPublisher가 declareCouponIssuedTopology로
// 같은 이름의 재시도 큐를 선언한다 — 다른 스펙(worker)과 같은 실제 브로커를 공유하므로 TTL 값을
// 반드시 통일해야 406(PRECONDITION_FAILED)이 안 난다.
process.env.RETRY_TTL_2S_MS = String(TEST_RETRY_TTL_MS[0]);
process.env.RETRY_TTL_8S_MS = String(TEST_RETRY_TTL_MS[1]);
process.env.RETRY_TTL_32S_MS = String(TEST_RETRY_TTL_MS[2]);

async function purgeQueue(channel: ConfirmChannel): Promise<void> {
  try {
    await channel.purgeQueue(COUPON_ISSUED_QUEUE);
  } catch {
    // 큐가 아직 없으면(첫 실행) 무시한다 — CouponEventPublisher.onModuleInit이 이후 생성한다.
  }
}

describe('CouponsService (async issuance integration)', () => {
  let service: CouponsService;
  let couponStockService: CouponStockService;
  let dataSource: DataSource;
  let valkeyClient: Redis;
  let rabbitmqChannel: TestChannel;
  let moduleRef: TestingModule;

  beforeAll(async () => {
    moduleRef = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot({ isGlobal: true }),
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
        TypeOrmModule.forFeature([Coupon]),
      ],
      providers: [
        CouponsService,
        CouponStockService,
        CouponEventPublisher,
        {
          provide: VALKEY_CLIENT,
          useFactory: () =>
            new Redis({
              host: process.env.TEST_VALKEY_HOST ?? 'localhost',
              port: Number(process.env.TEST_VALKEY_PORT ?? 6380),
            }),
        },
        { provide: RABBITMQ_CHANNEL, useFactory: connectTestChannel },
      ],
    }).compile();

    service = moduleRef.get(CouponsService);
    couponStockService = moduleRef.get(CouponStockService);
    dataSource = moduleRef.get(DataSource);
    valkeyClient = moduleRef.get(VALKEY_CLIENT);
    rabbitmqChannel = moduleRef.get(RABBITMQ_CHANNEL);
    await moduleRef.init(); // CouponEventPublisher.onModuleInit()이 exchange/queue를 생성한다
  });

  beforeEach(async () => {
    await dataSource.query(
      'TRUNCATE TABLE coupon_issues, coupons RESTART IDENTITY CASCADE',
    );
    await valkeyClient.flushdb();
    await purgeQueue(rabbitmqChannel);
  });

  afterAll(async () => {
    // moduleRef.close()가 Nest 라이프사이클(onApplicationShutdown)로 DataSource를 닫아준다.
    // 별도로 dataSource.destroy()를 부르면 이중 종료로 에러가 나 이후 정리 코드가 실행되지 않는다.
    await moduleRef.close();
    valkeyClient.disconnect();
    // channel.close()는 AMQP 채널만 닫고 TCP 연결은 남겨둔다 — 연결 자체를 닫아야
    // 프로세스가 열린 소켓 없이 정상 종료된다.
    await rabbitmqChannel.rawConnection.close();
  });

  async function countQueueMessages(): Promise<number> {
    const { messageCount } = await rabbitmqChannel.checkQueue(
      COUPON_ISSUED_QUEUE,
    );
    return messageCount;
  }

  it('재고 판정을 통과하면 202로 응답하고 큐에 메시지를 발행한다', async () => {
    const coupon = await service.create({
      title: '선착순 쿠폰',
      totalQuantity: 10,
      startAt: new Date(Date.now() - 60_000).toISOString(),
      endAt: new Date(Date.now() + 60 * 60_000).toISOString(),
    });

    const response = await service.issue(coupon.id, '1');

    expect(response).toEqual({ status: 'ACCEPTED' });
    expect(await countQueueMessages()).toBe(1);
  });

  it('존재하지 않는(워밍 안 된) 쿠폰은 NotFoundException을 던진다', async () => {
    await expect(service.issue('999999', '1')).rejects.toBeInstanceOf(
      NotFoundException,
    );
    expect(await countQueueMessages()).toBe(0);
  });

  it('재고 100개 / 서로 다른 유저 200명 동시 요청에서 정확히 100건만 성공하고 큐에도 100건만 쌓인다', async () => {
    const coupon = await service.create({
      title: '한정 100개 쿠폰',
      totalQuantity: 100,
      startAt: new Date(Date.now() - 60_000).toISOString(),
      endAt: new Date(Date.now() + 60 * 60_000).toISOString(),
    });

    const results = await Promise.allSettled(
      Array.from({ length: 200 }, (_, i) => service.issue(coupon.id, `${i}`)),
    );

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter(
      (r): r is PromiseRejectedResult => r.status === 'rejected',
    );

    expect(fulfilled).toHaveLength(100);
    expect(rejected).toHaveLength(100);
    for (const r of rejected) {
      expect(r.reason).toBeInstanceOf(BadRequestException);
    }
    expect(await countQueueMessages()).toBe(100);
  });

  it('동일 유저의 동시 중복 요청("따닥")은 1건만 성공한다', async () => {
    const coupon = await service.create({
      title: '중복 발급 방지 테스트 쿠폰',
      totalQuantity: 100,
      startAt: new Date(Date.now() - 60_000).toISOString(),
      endAt: new Date(Date.now() + 60 * 60_000).toISOString(),
    });

    const results = await Promise.allSettled(
      Array.from({ length: 10 }, () => service.issue(coupon.id, '1')),
    );

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter(
      (r): r is PromiseRejectedResult => r.status === 'rejected',
    );

    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(9);
    for (const r of rejected) {
      expect(r.reason).toBeInstanceOf(ConflictException);
    }
    expect(await countQueueMessages()).toBe(1);
  });

  it('메시지 발행이 실패하면 Valkey 예약을 되돌리고 503을 던진다 ("유령 차감" 방지)', async () => {
    const coupon = await service.create({
      title: '발행 실패 테스트 쿠폰',
      totalQuantity: 10,
      startAt: new Date(Date.now() - 60_000).toISOString(),
      endAt: new Date(Date.now() + 60 * 60_000).toISOString(),
    });

    const moduleRef = await Test.createTestingModule({
      providers: [
        CouponsService,
        { provide: getRepositoryToken(Coupon), useValue: {} },
        { provide: CouponStockService, useValue: couponStockService },
        {
          provide: CouponEventPublisher,
          useValue: {
            publishCouponIssued: jest
              .fn()
              .mockRejectedValue(new Error('channel closed')),
          },
        },
      ],
    }).compile();
    const failingService = moduleRef.get(CouponsService);

    await expect(failingService.issue(coupon.id, '1')).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    const stock = await couponStockService.getStock(coupon.id);
    expect(stock).toBe(10);
    // 예약이 롤백됐으니 같은 유저가 다시 시도하면 정상적으로 성공해야 한다
    await expect(service.issue(coupon.id, '1')).resolves.toEqual({
      status: 'ACCEPTED',
    });
  });
});
