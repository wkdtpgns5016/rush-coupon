import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { RabbitmqModule } from '../rabbitmq/rabbitmq.module';
import { ValkeyModule } from '../valkey/valkey.module';
import { Coupon } from './entities/coupon.entity';
import { CouponEventPublisher } from './coupon-event-publisher.service';
import { CouponStockService } from './coupon-stock.service';
import { CouponsController } from './coupons.controller';
import { CouponsService } from './coupons.service';

@Module({
  imports: [TypeOrmModule.forFeature([Coupon]), ValkeyModule, RabbitmqModule],
  controllers: [CouponsController],
  providers: [CouponsService, CouponStockService, CouponEventPublisher],
  exports: [CouponsService, CouponStockService, CouponEventPublisher],
})
export class CouponsModule {}
