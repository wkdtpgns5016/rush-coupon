import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, QueryFailedError, Repository } from 'typeorm';
import { Coupon } from './entities/coupon.entity';
import { CouponIssue } from './entities/coupon-issue.entity';
import { CreateCouponDto } from './dto/create-coupon.dto';

@Injectable()
export class CouponsService {
  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    @InjectRepository(Coupon) private readonly couponRepo: Repository<Coupon>,
  ) {}

  async create(dto: CreateCouponDto): Promise<Coupon> {
    const coupon = this.couponRepo.create({
      title: dto.title,
      totalQuantity: dto.totalQuantity,
      startAt: new Date(dto.startAt),
      endAt: new Date(dto.endAt),
    });
    return this.couponRepo.save(coupon);
  }

  async findOne(id: string): Promise<Coupon> {
    const coupon = await this.couponRepo.findOneBy({ id });
    if (!coupon) {
      throw new NotFoundException(`쿠폰을 찾을 수 없습니다. id=${id}`);
    }
    return coupon;
  }

  async issueWithPessimisticLock(
    couponId: string,
    userId: string,
  ): Promise<CouponIssue> {
    const queryRunner = this.dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();

    try {
      const coupon = await queryRunner.manager.findOne(Coupon, {
        where: { id: couponId },
        lock: { mode: 'pessimistic_write' },
      });

      if (!coupon) {
        throw new NotFoundException(`쿠폰을 찾을 수 없습니다. id=${couponId}`);
      }

      const now = new Date();
      if (now < coupon.startAt || now > coupon.endAt) {
        throw new BadRequestException('쿠폰 발급 기간이 아닙니다.');
      }

      if (coupon.issuedQuantity >= coupon.totalQuantity) {
        throw new BadRequestException('쿠폰 재고가 모두 소진되었습니다.');
      }

      const alreadyIssued = await queryRunner.manager.findOne(CouponIssue, {
        where: { couponId, userId },
      });
      if (alreadyIssued) {
        throw new ConflictException('이미 발급받은 쿠폰입니다.');
      }

      const issue = queryRunner.manager.create(CouponIssue, {
        couponId,
        userId,
      });
      await queryRunner.manager.save(issue);

      coupon.issuedQuantity += 1;
      await queryRunner.manager.save(coupon);

      await queryRunner.commitTransaction();
      return issue;
    } catch (err) {
      await queryRunner.rollbackTransaction();

      if (
        err instanceof QueryFailedError &&
        (err.driverError as { code?: string })?.code === '23505'
      ) {
        throw new ConflictException('이미 발급받은 쿠폰입니다.');
      }

      throw err;
    } finally {
      await queryRunner.release();
    }
  }
}
