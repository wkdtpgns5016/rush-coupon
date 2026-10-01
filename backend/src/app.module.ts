import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { PrometheusModule } from '@willsoto/nestjs-prometheus';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { Coupon } from './coupons/entities/coupon.entity';
import { CouponIssue } from './coupons/entities/coupon-issue.entity';
import { CouponsModule } from './coupons/coupons.module';
import { HealthModule } from './health/health.module';
import { HttpMetricsModule } from './metrics/http-metrics.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    PrometheusModule.register({
      defaultMetrics: { enabled: true },
      path: '/metrics',
    }),
    HttpMetricsModule,
    HealthModule,
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
        // RDS는 rds.force_ssl=1이 기본값이라 평문 연결을 거부한다("no pg_hba.conf entry
        // ... no encryption"). 온프레미스 자체 호스팅 Postgres는 SSL을 안 써서 기본값은 false.
        // 환경변수는 항상 문자열이라 get<boolean>는 타입만 속일 뿐 실제 변환을 안 해준다
        // ("false" 문자열도 JS에서는 truthy라서) — 그래서 문자열로 명시 비교한다.
        // RDS 인증서 체인이 Node 기본 trust store에 없을 수 있어 rejectUnauthorized는 꺼둔다
        // (짧은 검증 환경이라 CA 번들 설치까지는 하지 않음 — 운영 환경이면 RDS CA 번들로 검증해야 함).
        ssl:
          configService.get<string>('DB_SSL', 'false') === 'true'
            ? { rejectUnauthorized: false }
            : false,
        entities: [Coupon, CouponIssue],
        synchronize: false,
      }),
    }),
    CouponsModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
