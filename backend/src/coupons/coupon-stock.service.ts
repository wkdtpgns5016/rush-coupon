import { Inject, Injectable } from '@nestjs/common';
import Redis from 'ioredis';
import { VALKEY_CLIENT } from '../valkey/valkey.constants';

declare module 'ioredis' {
  interface RedisCommander<Context> {
    decrementCouponStock(key: string): Promise<number>;
  }
}

// KEYS[1]: 쿠폰 재고 키. 반환값: 1=차감 성공, 0=재고 소진, -1=캐시 미스(워밍 안 됨).
// GET → 조건 확인 → DECR을 하나의 EVAL로 묶어 동시 요청 사이의 race condition을 원천 차단한다.
const DECREMENT_STOCK_LUA = `
local stock = redis.call('GET', KEYS[1])
if stock == false then
  return -1
end
if tonumber(stock) <= 0 then
  return 0
end
redis.call('DECR', KEYS[1])
return 1
`;

export enum StockDecrementResult {
  SUCCESS = 'SUCCESS',
  SOLD_OUT = 'SOLD_OUT',
  NOT_WARMED = 'NOT_WARMED',
}

@Injectable()
export class CouponStockService {
  constructor(@Inject(VALKEY_CLIENT) private readonly client: Redis) {
    this.client.defineCommand('decrementCouponStock', {
      numberOfKeys: 1,
      lua: DECREMENT_STOCK_LUA,
    });
  }

  private stockKey(couponId: string): string {
    return `coupon:${couponId}:stock`;
  }

  async warmStock(couponId: string, quantity: number): Promise<void> {
    await this.client.set(this.stockKey(couponId), quantity);
  }

  async getStock(couponId: string): Promise<number | null> {
    const value = await this.client.get(this.stockKey(couponId));
    return value === null ? null : Number(value);
  }

  async decrementStock(couponId: string): Promise<StockDecrementResult> {
    const result = await this.client.decrementCouponStock(
      this.stockKey(couponId),
    );

    if (result === 1) return StockDecrementResult.SUCCESS;
    if (result === 0) return StockDecrementResult.SOLD_OUT;
    return StockDecrementResult.NOT_WARMED;
  }
}
