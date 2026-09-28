import * as amqplib from 'amqplib';
import type { ChannelModel, ConfirmChannel } from 'amqplib';

// amqplib의 Channel.close()는 AMQP 채널만 닫고 TCP 연결(ChannelModel)은 남겨둔다.
// 테스트가 끝나고 프로세스가 열린 소켓 없이 정상 종료되려면 연결 자체를 닫아야 하는데,
// Channel의 타입 선언(connection: Connection)에는 close()가 없어서 생성 시점의
// ChannelModel 참조를 별도로 들고 다녀야 한다.
export type TestChannel = ConfirmChannel & { rawConnection: ChannelModel };

export async function connectTestChannel(): Promise<TestChannel> {
  const host = process.env.TEST_RABBITMQ_HOST ?? 'localhost';
  const port = process.env.TEST_RABBITMQ_PORT ?? '5673';
  const username = process.env.TEST_RABBITMQ_USERNAME ?? 'rush';
  const password = process.env.TEST_RABBITMQ_PASSWORD ?? 'rush';
  const connection = await amqplib.connect(
    `amqp://${username}:${password}@${host}:${port}/`,
  );
  const channel = await connection.createConfirmChannel();
  return Object.assign(channel, { rawConnection: connection });
}
