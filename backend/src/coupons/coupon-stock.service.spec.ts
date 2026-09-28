import { Test } from '@nestjs/testing';
import Redis from 'ioredis';
import { CouponStockService, StockReservationResult } from './coupon-stock.service';
import { VALKEY_CLIENT } from '../valkey/valkey.constants';

jest.setTimeout(30000);

describe('CouponStockService (concurrency integration)', () => {
  let service: CouponStockService;
  let valkeyClient: Redis;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      providers: [
        CouponStockService,
        {
          provide: VALKEY_CLIENT,
          useFactory: () =>
            new Redis({
              host: process.env.TEST_VALKEY_HOST ?? 'localhost',
              port: Number(process.env.TEST_VALKEY_PORT ?? 6380),
            }),
        },
      ],
    }).compile();

    service = moduleRef.get(CouponStockService);
    valkeyClient = moduleRef.get(VALKEY_CLIENT);
  });

  beforeEach(async () => {
    await valkeyClient.flushdb();
  });

  afterAll(async () => {
    valkeyClient.disconnect();
  });

  it('워밍되지 않은 쿠폰은 NOT_WARMED를 반환한다', async () => {
    const result = await service.reserve('warmed-x', 'user-1');
    expect(result).toBe(StockReservationResult.NOT_WARMED);
  });

  it('재고 100개 / 서로 다른 유저 200명 동시 요청에서 정확히 100건만 SUCCESS를 받는다', async () => {
    const couponId = 'coupon-100';
    await service.warmStock(couponId, 100);

    const results = await Promise.all(
      Array.from({ length: 200 }, (_, i) => service.reserve(couponId, `user-${i}`)),
    );

    const success = results.filter((r) => r === StockReservationResult.SUCCESS);
    const soldOut = results.filter((r) => r === StockReservationResult.SOLD_OUT);

    expect(success).toHaveLength(100);
    expect(soldOut).toHaveLength(100);
    expect(await service.getStock(couponId)).toBe(0);
  });

  it('재고 소진 이후 요청은 SOLD_OUT을 반환하고 음수로 내려가지 않는다', async () => {
    const couponId = 'coupon-1';
    await service.warmStock(couponId, 1);

    expect(await service.reserve(couponId, 'user-1')).toBe(
      StockReservationResult.SUCCESS,
    );
    expect(await service.reserve(couponId, 'user-2')).toBe(
      StockReservationResult.SOLD_OUT,
    );
    expect(await service.getStock(couponId)).toBe(0);
  });

  it('동일 유저의 동시 중복 요청("따닥")은 1건만 SUCCESS를 받는다', async () => {
    const couponId = 'coupon-dup';
    await service.warmStock(couponId, 100);

    const results = await Promise.all(
      Array.from({ length: 10 }, () => service.reserve(couponId, 'user-1')),
    );

    const success = results.filter((r) => r === StockReservationResult.SUCCESS);
    const duplicate = results.filter(
      (r) => r === StockReservationResult.DUPLICATE,
    );

    expect(success).toHaveLength(1);
    expect(duplicate).toHaveLength(9);
    expect(await service.getStock(couponId)).toBe(99);
  });

  it('release()는 재고와 중복 방지 등록을 원상 복구한다', async () => {
    const couponId = 'coupon-release';
    await service.warmStock(couponId, 5);

    expect(await service.reserve(couponId, 'user-1')).toBe(
      StockReservationResult.SUCCESS,
    );
    expect(await service.getStock(couponId)).toBe(4);

    await service.release(couponId, 'user-1');

    expect(await service.getStock(couponId)).toBe(5);
    expect(await service.reserve(couponId, 'user-1')).toBe(
      StockReservationResult.SUCCESS,
    );
  });
});
