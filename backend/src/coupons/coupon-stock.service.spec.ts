import { Test } from '@nestjs/testing';
import Redis from 'ioredis';
import { CouponStockService, StockDecrementResult } from './coupon-stock.service';
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
    const result = await service.decrementStock('warmed-x');
    expect(result).toBe(StockDecrementResult.NOT_WARMED);
  });

  it('재고 100개 / 동시 요청 200건에서 정확히 100건만 SUCCESS를 받는다', async () => {
    const couponId = 'coupon-100';
    await service.warmStock(couponId, 100);

    const results = await Promise.all(
      Array.from({ length: 200 }, () => service.decrementStock(couponId)),
    );

    const success = results.filter((r) => r === StockDecrementResult.SUCCESS);
    const soldOut = results.filter((r) => r === StockDecrementResult.SOLD_OUT);

    expect(success).toHaveLength(100);
    expect(soldOut).toHaveLength(100);
    expect(await service.getStock(couponId)).toBe(0);
  });

  it('재고 소진 이후 요청은 SOLD_OUT을 반환하고 음수로 내려가지 않는다', async () => {
    const couponId = 'coupon-1';
    await service.warmStock(couponId, 1);

    expect(await service.decrementStock(couponId)).toBe(
      StockDecrementResult.SUCCESS,
    );
    expect(await service.decrementStock(couponId)).toBe(
      StockDecrementResult.SOLD_OUT,
    );
    expect(await service.getStock(couponId)).toBe(0);
  });
});
