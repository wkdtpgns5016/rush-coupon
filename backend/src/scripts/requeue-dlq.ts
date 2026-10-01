// 원인(DB 장애 등)을 해결한 뒤, coupon.issued.dlq에 격리된 메시지를 다시 정상 처리 큐(coupon.issued)로
// 되돌리는 운영용 스크립트. Worker와 같은 이미지에 들어있어 배포를 새로 할 필요 없이 그 자리에서 실행한다.
//
//   node dist/scripts/requeue-dlq.js              # DLQ에 쌓인 메시지를 모두 coupon.issued로 재발행
//   node dist/scripts/requeue-dlq.js --dry-run     # 실제로 옮기지 않고 현재 DLQ 메시지 수만 확인
//   node dist/scripts/requeue-dlq.js --limit 2     # 앞에서부터 2건만 재발행(카나리아 테스트용)
//
// 장애 원인이 정말 해결됐는지는 이 스크립트가 판단해주지 않는다 — 전체를 한 번에 되돌렸다가 원인이
// 안 고쳐졌으면 같은 backlog가 통째로 다시 실패한다. --limit으로 소수만 먼저 되돌려 Worker 로그에서
// 정상 처리되는지 확인한 뒤, 문제없으면 --limit 없이 나머지를 마저 옮기는 식으로 쓴다.
//
// 참고: 재발행되는 메시지는 기존 x-death 헤더를 그대로 들고 간다. 즉 다시 실패하면 재시도 사다리를
// 처음부터(2s) 밟지 않고 곧장 다시 DLQ로 격리된다 — 이미 전체 재시도를 소진했던 메시지이므로
// 의도된 동작이다.
import * as amqplib from 'amqplib';
import type { ConfirmChannel } from 'amqplib';
import {
  COUPON_EXCHANGE,
  COUPON_ISSUED_DLQ,
  COUPON_ISSUED_ROUTING_KEY,
} from '../coupons/coupon-messaging.constants';

export interface RequeueDlqResult {
  found: number;
  requeued: number;
}

// 실행 시점 기준 큐 길이(found)만큼만 처리한다 — 스크립트가 도는 중에 새로 DLQ에 들어오는
// 메시지는 이번 실행에서 건드리지 않는다(무한 루프 방지). limit을 주면 그중 앞에서부터
// limit건까지만 처리한다(카나리아 테스트용).
export async function requeueDlq(
  channel: ConfirmChannel,
  { dryRun = false, limit }: { dryRun?: boolean; limit?: number } = {},
): Promise<RequeueDlqResult> {
  const { messageCount: found } = await channel.checkQueue(COUPON_ISSUED_DLQ);
  if (found === 0 || dryRun) {
    return { found, requeued: 0 };
  }

  const toProcess = limit === undefined ? found : Math.min(found, limit);
  let requeued = 0;
  for (let i = 0; i < toProcess; i++) {
    const message = await channel.get(COUPON_ISSUED_DLQ, { noAck: false });
    if (!message) break; // 다른 프로세스가 먼저 가져갔거나 이미 비었음

    await new Promise<void>((resolve, reject) => {
      channel.publish(
        COUPON_EXCHANGE,
        COUPON_ISSUED_ROUTING_KEY,
        message.content,
        {
          persistent: true,
          contentType: message.properties.contentType,
          headers: message.properties.headers,
        },
        (err) => (err ? reject(err) : resolve()),
      );
    });
    channel.ack(message);
    requeued += 1;
  }

  return { found, requeued };
}

export function parseLimitArg(argv: string[]): number | undefined {
  const index = argv.indexOf('--limit');
  if (index === -1) return undefined;

  const value = Number(argv[index + 1]);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error('--limit 뒤에는 0 이상의 정수를 지정해야 합니다.');
  }
  return value;
}

async function main(): Promise<void> {
  const dryRun = process.argv.includes('--dry-run');
  const limit = parseLimitArg(process.argv);

  const host = process.env.RABBITMQ_HOST ?? 'localhost';
  const port = process.env.RABBITMQ_PORT ?? '5672';
  const username = process.env.RABBITMQ_USERNAME ?? 'guest';
  const password = process.env.RABBITMQ_PASSWORD ?? 'guest';
  const protocol = process.env.RABBITMQ_PROTOCOL ?? 'amqp';

  const connection = await amqplib.connect(
    `${protocol}://${username}:${password}@${host}:${port}/`,
  );
  const channel = await connection.createConfirmChannel();

  try {
    const { found, requeued } = await requeueDlq(channel, { dryRun, limit });
    console.log(`DLQ(${COUPON_ISSUED_DLQ})에 ${found}건이 있었습니다.`);
    if (dryRun) {
      console.log('--dry-run 이라 아무것도 옮기지 않았습니다.');
    } else {
      console.log(`${requeued}건을 ${COUPON_ISSUED_ROUTING_KEY} 큐로 재발행했습니다.`);
    }
  } finally {
    await connection.close();
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error('DLQ 재발행 실패:', err);
    process.exitCode = 1;
  });
}
