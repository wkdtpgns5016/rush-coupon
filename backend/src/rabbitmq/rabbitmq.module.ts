import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import * as amqplib from 'amqplib';
import { RABBITMQ_CHANNEL } from './rabbitmq.constants';

@Module({
  imports: [ConfigModule],
  providers: [
    {
      provide: RABBITMQ_CHANNEL,
      inject: [ConfigService],
      useFactory: async (configService: ConfigService) => {
        const host = configService.get<string>('RABBITMQ_HOST', 'localhost');
        const port = configService.get<number>('RABBITMQ_PORT', 5672);
        const username = configService.get<string>('RABBITMQ_USERNAME', 'guest');
        const password = configService.get<string>('RABBITMQ_PASSWORD', 'guest');
        const vhost = configService.get<string>('RABBITMQ_VHOST', '/');

        const connection = await amqplib.connect(
          `amqp://${username}:${password}@${host}:${port}/${encodeURIComponent(vhost)}`,
        );
        return connection.createConfirmChannel();
      },
    },
  ],
  exports: [RABBITMQ_CHANNEL],
})
export class RabbitmqModule {}
