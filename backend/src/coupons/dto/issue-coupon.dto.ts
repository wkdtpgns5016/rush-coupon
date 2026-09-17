import { IsNotEmpty, IsNumberString } from 'class-validator';

export class IssueCouponDto {
  @IsNotEmpty()
  @IsNumberString()
  userId: string;
}
