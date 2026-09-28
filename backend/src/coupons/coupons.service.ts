import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { CouponEventPublisher } from './coupon-event-publisher.service';
import { CouponStockService, StockReservationResult } from './coupon-stock.service';
import { Coupon } from './entities/coupon.entity';
import { CreateCouponDto } from './dto/create-coupon.dto';

@Injectable()
export class CouponsService {
  private readonly logger = new Logger(CouponsService.name);

  constructor(
    @InjectRepository(Coupon) private readonly couponRepo: Repository<Coupon>,
    private readonly couponStockService: CouponStockService,
    private readonly couponEventPublisher: CouponEventPublisher,
  ) {}

  async create(dto: CreateCouponDto): Promise<Coupon> {
    const coupon = this.couponRepo.create({
      title: dto.title,
      totalQuantity: dto.totalQuantity,
      startAt: new Date(dto.startAt),
      endAt: new Date(dto.endAt),
    });
    const saved = await this.couponRepo.save(coupon);
    await this.couponStockService.warmStock(saved.id, saved.totalQuantity);
    return saved;
  }

  async findOne(id: string): Promise<Coupon> {
    const coupon = await this.couponRepo.findOneBy({ id });
    if (!coupon) {
      throw new NotFoundException(`쿠폰을 찾을 수 없습니다. id=${id}`);
    }
    return coupon;
  }

  // Valkey에서 재고/중복을 원자적으로 판정한 뒤, 통과한 요청만 RabbitMQ에 발행하고 즉시 202로 응답한다.
  // DB 영속화는 Worker(별도 이슈)가 큐를 consume해 비동기로 처리한다.
  async issue(couponId: string, userId: string): Promise<{ status: 'ACCEPTED' }> {
    const result = await this.couponStockService.reserve(couponId, userId);

    if (result === StockReservationResult.NOT_WARMED) {
      throw new NotFoundException(`쿠폰을 찾을 수 없습니다. id=${couponId}`);
    }
    if (result === StockReservationResult.SOLD_OUT) {
      throw new BadRequestException('쿠폰 재고가 모두 소진되었습니다.');
    }
    if (result === StockReservationResult.DUPLICATE) {
      throw new ConflictException('이미 발급받은 쿠폰입니다.');
    }

    try {
      await this.couponEventPublisher.publishCouponIssued({
        couponId,
        userId,
        requestedAt: new Date().toISOString(),
      });
    } catch (err) {
      // "유령 차감" 방지: 메시지 발행이 실패하면 Valkey에 반영된 예약(재고 차감·중복 방지 등록)을 되돌린다.
      await this.couponStockService.release(couponId, userId);
      this.logger.error(
        `쿠폰 발급 이벤트 발행 실패 couponId=${couponId} userId=${userId}`,
        err instanceof Error ? err.stack : err,
      );
      throw new ServiceUnavailableException(
        '쿠폰 발급 처리에 실패했습니다. 다시 시도해주세요.',
      );
    }

    return { status: 'ACCEPTED' };
  }
}
