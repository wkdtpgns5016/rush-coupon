import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ValkeyModule } from '../valkey/valkey.module';
import { Coupon } from './entities/coupon.entity';
import { CouponIssue } from './entities/coupon-issue.entity';
import { CouponStockService } from './coupon-stock.service';
import { CouponsController } from './coupons.controller';
import { CouponsService } from './coupons.service';

@Module({
  imports: [TypeOrmModule.forFeature([Coupon, CouponIssue]), ValkeyModule],
  controllers: [CouponsController],
  providers: [CouponsService, CouponStockService],
  exports: [CouponsService, CouponStockService],
})
export class CouponsModule {}
