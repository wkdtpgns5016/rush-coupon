import { Inject, Module, OnModuleDestroy } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import * as amqplib from 'amqplib';
import type { ChannelModel } from 'amqplib';
import { RABBITMQ_CHANNEL, RABBITMQ_CONNECTION } from './rabbitmq.constants';

@Module({
  imports: [ConfigModule],
  providers: [
    {
      provide: RABBITMQ_CONNECTION,
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => {
        const host = configService.get<string>('RABBITMQ_HOST', 'localhost');
        const port = configService.get<number>('RABBITMQ_PORT', 5672);
        const username = configService.get<string>('RABBITMQ_USERNAME', 'guest');
        const password = configService.get<string>('RABBITMQ_PASSWORD', 'guest');
        const vhost = configService.get<string>('RABBITMQ_VHOST', '/');

        return amqplib.connect(
          `amqp://${username}:${password}@${host}:${port}/${encodeURIComponent(vhost)}`,
        );
      },
    },
    {
      provide: RABBITMQ_CHANNEL,
      inject: [RABBITMQ_CONNECTION],
      useFactory: (connection: ChannelModel) => connection.createConfirmChannel(),
    },
  ],
  exports: [RABBITMQ_CHANNEL],
})
export class RabbitmqModule implements OnModuleDestroy {
  constructor(
    @Inject(RABBITMQ_CONNECTION) private readonly connection: ChannelModel,
  ) {}

  // channel.close()는 AMQP 채널만 닫고 TCP 연결은 남겨둔다 — graceful shutdown(worker.main.ts의
  // enableShutdownHooks) 시 연결 자체를 닫아야 브로커가 미확인 메시지를 지연 없이 다른 컨슈머에게 재전달한다.
  async onModuleDestroy(): Promise<void> {
    await this.connection.close();
  }
}
