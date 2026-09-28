import type { ConsumeMessage } from 'amqplib';
import { determineNextRoutingKey } from './coupon-retry-router.service';

function fakeMessage(deathQueues: string[]): ConsumeMessage {
  return {
    properties: {
      headers: {
        'x-death': deathQueues.map((queue) => ({
          queue,
          reason: 'expired',
          count: 1,
        })),
      },
    },
  } as unknown as ConsumeMessage;
}

describe('determineNextRoutingKey', () => {
  it('x-death 이력이 없으면 첫 단계(2s)로 보낸다', () => {
    expect(determineNextRoutingKey(fakeMessage([]))).toBe('2s');
  });

  it('2s 큐를 거쳤으면 다음 단계(8s)로 보낸다', () => {
    expect(determineNextRoutingKey(fakeMessage(['coupon.retry.2s']))).toBe(
      '8s',
    );
  });

  it('2s, 8s를 거쳤으면 다음 단계(32s)로 보낸다', () => {
    expect(
      determineNextRoutingKey(fakeMessage(['coupon.retry.2s', 'coupon.retry.8s'])),
    ).toBe('32s');
  });

  it('2s, 8s, 32s를 모두 거쳤으면 DLQ로 보낸다', () => {
    expect(
      determineNextRoutingKey(
        fakeMessage(['coupon.retry.2s', 'coupon.retry.8s', 'coupon.retry.32s']),
      ),
    ).toBe('dlq');
  });

  it('x-death 순서가 뒤섞여 있어도 가장 늦은 단계 기준으로 판단한다', () => {
    expect(
      determineNextRoutingKey(
        fakeMessage(['coupon.retry.8s', 'coupon.retry.2s']),
      ),
    ).toBe('32s');
  });

  it('헤더 자체가 없는 메시지(첫 발행)는 첫 단계로 보낸다', () => {
    const message = { properties: { headers: undefined } } as unknown as ConsumeMessage;
    expect(determineNextRoutingKey(message)).toBe('2s');
  });
});
