import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import Redis from 'ioredis';
import { VALKEY_CLIENT } from './valkey.constants';

@Module({
  imports: [ConfigModule],
  providers: [
    {
      provide: VALKEY_CLIENT,
      inject: [ConfigService],
      useFactory: (configService: ConfigService) =>
        new Redis({
          host: configService.get<string>('VALKEY_HOST', 'localhost'),
          port: configService.get<number>('VALKEY_PORT', 6379),
        }),
    },
  ],
  exports: [VALKEY_CLIENT],
})
export class ValkeyModule {}
