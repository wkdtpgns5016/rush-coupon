export interface Coupon {
  id: string;
  title: string;
  totalQuantity: number;
  issuedQuantity: number;
  startAt: string;
  endAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface CouponIssue {
  id: string;
  couponId: string;
  userId: string;
  issuedAt: string;
}

export type IssueErrorKind =
  | 'SOLD_OUT'
  | 'INVALID_PERIOD'
  | 'DUPLICATE'
  | 'NOT_FOUND'
  | 'UNKNOWN';

export class ApiError extends Error {
  status: number;
  kind: IssueErrorKind;

  constructor(status: number, message: string, kind: IssueErrorKind) {
    super(message);
    this.status = status;
    this.kind = kind;
  }
}

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3000';

async function toApiError(res: Response): Promise<ApiError> {
  const body = await res
    .json()
    .catch(() => ({ message: '알 수 없는 오류가 발생했습니다.' }));
  const message: string = body.message ?? '알 수 없는 오류가 발생했습니다.';

  let kind: IssueErrorKind = 'UNKNOWN';
  if (res.status === 400 && message === '쿠폰 재고가 모두 소진되었습니다.') {
    kind = 'SOLD_OUT';
  } else if (res.status === 400 && message === '쿠폰 발급 기간이 아닙니다.') {
    kind = 'INVALID_PERIOD';
  } else if (res.status === 409) {
    kind = 'DUPLICATE';
  } else if (res.status === 404) {
    kind = 'NOT_FOUND';
  }

  return new ApiError(res.status, message, kind);
}

export async function getCoupon(id: string): Promise<Coupon> {
  const res = await fetch(`${BASE_URL}/coupons/${id}`);
  if (!res.ok) {
    throw await toApiError(res);
  }
  return res.json();
}

export async function issueCoupon(
  id: string,
  userId: string,
): Promise<CouponIssue> {
  const res = await fetch(`${BASE_URL}/coupons/${id}/issue`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ userId }),
  });
  if (!res.ok) {
    throw await toApiError(res);
  }
  return res.json();
}
