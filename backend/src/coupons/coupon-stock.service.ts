import { Inject, Injectable } from '@nestjs/common';
import Redis from 'ioredis';
import { VALKEY_CLIENT } from '../valkey/valkey.constants';

declare module 'ioredis' {
  interface RedisCommander<Context> {
    reserveCouponStock(stockKey: string, issuedUsersKey: string, userId: string): Promise<number>;
    releaseCouponStock(stockKey: string, issuedUsersKey: string, userId: string): Promise<'OK'>;
  }
}

// KEYS[1]: 재고 키, KEYS[2]: 발급받은 유저 집합, ARGV[1]: userId
// 반환값: 1=예약 성공, 0=재고 소진, -1=캐시 미스(워밍 안 됨), -2=중복 발급
// "이미 받았는지" 판정을 "재고가 있는지" 판정보다 먼저 원자적으로 처리해, 동시 요청 사이의
// race condition(중복 발급·초과 발급)을 하나의 EVAL로 전부 차단한다.
// 성공으로 이어지지 않는 경로는 SADD로 추가한 멤버십을 되돌려, 그 유저가 실제로 못 받았는데도
// "이미 받은 것"으로 영구히 막히지 않게 한다.
const RESERVE_STOCK_LUA = `
local added = redis.call('SADD', KEYS[2], ARGV[1])
if added == 0 then
  return -2
end

local stock = redis.call('GET', KEYS[1])
if stock == false then
  redis.call('SREM', KEYS[2], ARGV[1])
  return -1
end

if tonumber(stock) <= 0 then
  redis.call('SREM', KEYS[2], ARGV[1])
  return 0
end

redis.call('DECR', KEYS[1])
return 1
`;

// 예약(reserve) 이후 후속 단계(RabbitMQ publish 등)가 실패했을 때 되돌리는 보상 트랜잭션.
const RELEASE_STOCK_LUA = `
redis.call('SREM', KEYS[2], ARGV[1])
redis.call('INCR', KEYS[1])
return redis.status_reply('OK')
`;

export enum StockReservationResult {
  SUCCESS = 'SUCCESS',
  SOLD_OUT = 'SOLD_OUT',
  DUPLICATE = 'DUPLICATE',
  NOT_WARMED = 'NOT_WARMED',
}

@Injectable()
export class CouponStockService {
  constructor(@Inject(VALKEY_CLIENT) private readonly client: Redis) {
    this.client.defineCommand('reserveCouponStock', {
      numberOfKeys: 2,
      lua: RESERVE_STOCK_LUA,
    });
    this.client.defineCommand('releaseCouponStock', {
      numberOfKeys: 2,
      lua: RELEASE_STOCK_LUA,
    });
  }

  private stockKey(couponId: string): string {
    return `coupon:${couponId}:stock`;
  }

  private issuedUsersKey(couponId: string): string {
    return `coupon:${couponId}:issued-users`;
  }

  async warmStock(couponId: string, quantity: number): Promise<void> {
    await this.client.set(this.stockKey(couponId), quantity);
  }

  async getStock(couponId: string): Promise<number | null> {
    const value = await this.client.get(this.stockKey(couponId));
    return value === null ? null : Number(value);
  }

  async reserve(couponId: string, userId: string): Promise<StockReservationResult> {
    const result = await this.client.reserveCouponStock(
      this.stockKey(couponId),
      this.issuedUsersKey(couponId),
      userId,
    );

    if (result === 1) return StockReservationResult.SUCCESS;
    if (result === 0) return StockReservationResult.SOLD_OUT;
    if (result === -2) return StockReservationResult.DUPLICATE;
    return StockReservationResult.NOT_WARMED;
  }

  async release(couponId: string, userId: string): Promise<void> {
    await this.client.releaseCouponStock(
      this.stockKey(couponId),
      this.issuedUsersKey(couponId),
      userId,
    );
  }
}
