import {
  Column,
  CreateDateColumn,
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryGeneratedColumn,
  Unique,
} from 'typeorm';
import { Coupon } from './coupon.entity';

@Entity('coupon_issues')
@Unique('uq_coupon_user', ['couponId', 'userId'])
export class CouponIssue {
  @PrimaryGeneratedColumn({ type: 'bigint' })
  id: string;

  @Column({ name: 'coupon_id', type: 'bigint' })
  couponId: string;

  @Column({ name: 'user_id', type: 'bigint' })
  userId: string;

  @CreateDateColumn({ name: 'issued_at', type: 'timestamptz' })
  issuedAt: Date;

  // 발급 요청(enqueue) 시각 — RabbitMQ 메시지의 requestedAt을 그대로 저장한다.
  // issuedAt(저장 완료 시각)과의 차이로 큐 적재→Worker 저장까지의 종단 지연을 계산하는 데 쓴다.
  @Column({ name: 'requested_at', type: 'timestamptz', nullable: true })
  requestedAt: Date | null;

  @ManyToOne(() => Coupon, { onDelete: 'RESTRICT' })
  @JoinColumn({ name: 'coupon_id' })
  coupon: Coupon;
}
