import { IsDateString, IsInt, IsNotEmpty, Min } from 'class-validator';

export class CreateCouponDto {
  @IsNotEmpty()
  title: string;

  @IsInt()
  @Min(1)
  totalQuantity: number;

  @IsDateString()
  startAt: string;

  @IsDateString()
  endAt: string;
}
