import {
  COUPON_ISSUED_DLQ,
  COUPON_ISSUED_QUEUE,
  COUPON_RETRY_EXCHANGE,
  DLQ_ROUTING_KEY,
  RETRY_STAGES,
} from '../coupons/coupon-messaging.constants';
import { declareCouponIssuedTopology } from '../coupons/coupon-event-publisher.service';
import { connectTestChannel, TestChannel } from '../test-utils/rabbitmq-test-channel';
import { TEST_RETRY_TTL_MS } from '../test-utils/retry-ttl';
import { parseLimitArg, requeueDlq } from './requeue-dlq';

jest.setTimeout(30000);

describe('parseLimitArg', () => {
  it('--limit이 없으면 undefined를 반환한다', () => {
    expect(parseLimitArg(['node', 'requeue-dlq.js'])).toBeUndefined();
  });

  it('--limit 뒤의 정수를 반환한다', () => {
    expect(parseLimitArg(['node', 'requeue-dlq.js', '--limit', '3'])).toBe(3);
  });

  it('--limit 값이 정수가 아니면 에러를 던진다', () => {
    expect(() =>
      parseLimitArg(['node', 'requeue-dlq.js', '--limit', 'abc']),
    ).toThrow();
  });

  it('--limit 값이 음수면 에러를 던진다', () => {
    expect(() =>
      parseLimitArg(['node', 'requeue-dlq.js', '--limit', '-1']),
    ).toThrow();
  });
});

describe('requeueDlq', () => {
  let channel: TestChannel;

  beforeAll(async () => {
    channel = await connectTestChannel();
    await declareCouponIssuedTopology(channel, { retryTtlMs: TEST_RETRY_TTL_MS });
  });

  beforeEach(async () => {
    await channel.purgeQueue(COUPON_ISSUED_QUEUE);
    await channel.purgeQueue(COUPON_ISSUED_DLQ);
    for (const stage of RETRY_STAGES) {
      await channel.purgeQueue(stage.queue);
    }
  });

  afterAll(async () => {
    await channel.rawConnection.close();
  });

  function publishToDlq(payload: unknown): Promise<void> {
    return new Promise((resolve, reject) => {
      channel.publish(
        COUPON_RETRY_EXCHANGE,
        DLQ_ROUTING_KEY,
        Buffer.from(JSON.stringify(payload)),
        { persistent: true, contentType: 'application/json' },
        (err) => (err ? reject(err) : resolve()),
      );
    });
  }

  async function queueCount(queue: string): Promise<number> {
    const { messageCount } = await channel.checkQueue(queue);
    return messageCount;
  }

  it('DLQ가 비어있으면 아무 것도 하지 않는다', async () => {
    const result = await requeueDlq(channel);
    expect(result).toEqual({ found: 0, requeued: 0 });
  });

  it('DLQ에 있는 메시지를 모두 coupon.issued로 재발행한다', async () => {
    await publishToDlq({ couponId: '1', userId: '1' });
    await publishToDlq({ couponId: '1', userId: '2' });

    const result = await requeueDlq(channel);

    expect(result).toEqual({ found: 2, requeued: 2 });
    expect(await queueCount(COUPON_ISSUED_DLQ)).toBe(0);
    expect(await queueCount(COUPON_ISSUED_QUEUE)).toBe(2);
  });

  it('dryRun이면 개수만 세고 실제로 옮기지 않는다', async () => {
    await publishToDlq({ couponId: '1', userId: '1' });

    const result = await requeueDlq(channel, { dryRun: true });

    expect(result).toEqual({ found: 1, requeued: 0 });
    expect(await queueCount(COUPON_ISSUED_DLQ)).toBe(1);
    expect(await queueCount(COUPON_ISSUED_QUEUE)).toBe(0);
  });

  it('limit을 주면 그만큼만 재발행하고 나머지는 DLQ에 남긴다(카나리아 테스트)', async () => {
    await publishToDlq({ couponId: '1', userId: '1' });
    await publishToDlq({ couponId: '1', userId: '2' });
    await publishToDlq({ couponId: '1', userId: '3' });

    const result = await requeueDlq(channel, { limit: 1 });

    expect(result).toEqual({ found: 3, requeued: 1 });
    expect(await queueCount(COUPON_ISSUED_DLQ)).toBe(2);
    expect(await queueCount(COUPON_ISSUED_QUEUE)).toBe(1);
  });

  it('limit이 실제 개수보다 크면 있는 만큼만 재발행한다', async () => {
    await publishToDlq({ couponId: '1', userId: '1' });

    const result = await requeueDlq(channel, { limit: 10 });

    expect(result).toEqual({ found: 1, requeued: 1 });
    expect(await queueCount(COUPON_ISSUED_DLQ)).toBe(0);
    expect(await queueCount(COUPON_ISSUED_QUEUE)).toBe(1);
  });
});
