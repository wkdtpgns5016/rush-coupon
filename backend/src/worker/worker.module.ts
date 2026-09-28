import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { RabbitmqModule } from '../rabbitmq/rabbitmq.module';
import { Coupon } from '../coupons/entities/coupon.entity';
import { CouponIssue } from '../coupons/entities/coupon-issue.entity';
import { CouponIssueConsumerService } from './coupon-issue-consumer.service';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    TypeOrmModule.forRootAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        type: 'postgres' as const,
        host: configService.get<string>('DB_HOST', 'localhost'),
        port: configService.get<number>('DB_PORT', 5432),
        username: configService.get<string>('DB_USERNAME', 'postgres'),
        password: configService.get<string>('DB_PASSWORD', 'postgres'),
        database: configService.get<string>('DB_DATABASE', 'rush_coupon'),
        entities: [Coupon, CouponIssue],
        synchronize: false,
        // 배치 flush마다 커넥션 하나만 짧게 쓰는 구조라, backend API 풀보다 훨씬 작게 잡아
        // Postgres 커넥션 부하를 최소화한다.
        extra: { max: configService.get<number>('WORKER_DB_POOL_MAX', 5) },
      }),
    }),
    TypeOrmModule.forFeature([CouponIssue]),
    RabbitmqModule,
  ],
  providers: [CouponIssueConsumerService],
})
export class WorkerModule {}
