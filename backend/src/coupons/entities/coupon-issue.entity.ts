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

  @ManyToOne(() => Coupon, { onDelete: 'RESTRICT' })
  @JoinColumn({ name: 'coupon_id' })
  coupon: Coupon;
}
