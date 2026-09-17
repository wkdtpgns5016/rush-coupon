import { ConflictException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { TypeOrmModule } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { CouponsService } from './coupons.service';
import { Coupon } from './entities/coupon.entity';
import { CouponIssue } from './entities/coupon-issue.entity';

jest.setTimeout(30000);

describe('CouponsService (concurrency integration)', () => {
  let service: CouponsService;
  let dataSource: DataSource;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      imports: [
        TypeOrmModule.forRoot({
          type: 'postgres',
          host: process.env.TEST_DB_HOST ?? 'localhost',
          port: Number(process.env.TEST_DB_PORT ?? 5433),
          username: process.env.DB_USERNAME ?? 'postgres',
          password: process.env.DB_PASSWORD ?? 'postgres',
          database: process.env.DB_DATABASE ?? 'rush_coupon',
          entities: [Coupon, CouponIssue],
          synchronize: false,
        }),
        TypeOrmModule.forFeature([Coupon, CouponIssue]),
      ],
      providers: [CouponsService],
    }).compile();

    service = moduleRef.get(CouponsService);
    dataSource = moduleRef.get(DataSource);
  });

  beforeEach(async () => {
    await dataSource.query(
      'TRUNCATE TABLE coupon_issues, coupons RESTART IDENTITY CASCADE',
    );
  });

  afterAll(async () => {
    await dataSource.destroy();
  });

  it('한정 수량을 초과해서 발급하지 않는다 (재고 100개 / 동시 요청 200건)', async () => {
    const coupon = await service.create({
      title: '선착순 100명 쿠폰',
      totalQuantity: 100,
      startAt: new Date(Date.now() - 60_000).toISOString(),
      endAt: new Date(Date.now() + 60 * 60_000).toISOString(),
    });

    const userIds = Array.from({ length: 200 }, (_, i) => String(i + 1));
    const results = await Promise.allSettled(
      userIds.map((userId) =>
        service.issueWithPessimisticLock(coupon.id, userId),
      ),
    );

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter((r) => r.status === 'rejected');

    expect(fulfilled).toHaveLength(100);
    expect(rejected).toHaveLength(100);

    const updatedCoupon = await service.findOne(coupon.id);
    expect(updatedCoupon.issuedQuantity).toBe(100);

    const issueCount = await dataSource
      .getRepository(CouponIssue)
      .count({ where: { couponId: coupon.id } });
    expect(issueCount).toBe(100);
  });

  it('동일 유저의 동시 중복 요청("따닥")은 1건만 발급한다', async () => {
    const coupon = await service.create({
      title: '중복 발급 방지 테스트 쿠폰',
      totalQuantity: 100,
      startAt: new Date(Date.now() - 60_000).toISOString(),
      endAt: new Date(Date.now() + 60 * 60_000).toISOString(),
    });

    const userId = '1';
    const results = await Promise.allSettled(
      Array.from({ length: 10 }, () =>
        service.issueWithPessimisticLock(coupon.id, userId),
      ),
    );

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter(
      (r): r is PromiseRejectedResult => r.status === 'rejected',
    );

    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(9);
    for (const r of rejected) {
      expect(r.reason).toBeInstanceOf(ConflictException);
    }

    const updatedCoupon = await service.findOne(coupon.id);
    expect(updatedCoupon.issuedQuantity).toBe(1);

    const issueCount = await dataSource
      .getRepository(CouponIssue)
      .count({ where: { couponId: coupon.id, userId } });
    expect(issueCount).toBe(1);
  });
});
