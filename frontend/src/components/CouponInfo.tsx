import type { Coupon } from '../api/coupons';

interface CouponInfoProps {
  coupon: Coupon | null;
  loading: boolean;
  error: string | null;
  onRefresh: () => void;
}

function formatDateRange(startAt: string, endAt: string): string {
  const start = new Date(startAt).toLocaleString();
  const end = new Date(endAt).toLocaleString();
  return `${start} ~ ${end}`;
}

export function CouponInfo({ coupon, loading, error, onRefresh }: CouponInfoProps) {
  const remaining = coupon ? coupon.totalQuantity - coupon.issuedQuantity : null;

  return (
    <section className="rounded-xl border border-gray-200 bg-white p-5 shadow-sm dark:border-gray-700 dark:bg-gray-800">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">
          쿠폰 정보
        </h2>
        <button
          type="button"
          onClick={onRefresh}
          disabled={loading}
          className="rounded-md border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 transition hover:bg-gray-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-700"
        >
          새로고침
        </button>
      </div>

      {loading && !coupon && (
        <p className="text-sm text-gray-500 dark:text-gray-400">불러오는 중...</p>
      )}
      {error && (
        <p className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}

      {coupon && (
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
          <dt className="text-gray-500 dark:text-gray-400">쿠폰명</dt>
          <dd className="font-medium text-gray-900 dark:text-gray-100">
            {coupon.title}
          </dd>

          <dt className="text-gray-500 dark:text-gray-400">이벤트 기간</dt>
          <dd className="font-medium text-gray-900 dark:text-gray-100">
            {formatDateRange(coupon.startAt, coupon.endAt)}
          </dd>

          <dt className="text-gray-500 dark:text-gray-400">총 수량</dt>
          <dd className="font-medium text-gray-900 dark:text-gray-100">
            {coupon.totalQuantity}
          </dd>

          <dt className="text-gray-500 dark:text-gray-400">발급된 수량</dt>
          <dd className="font-medium text-gray-900 dark:text-gray-100">
            {coupon.issuedQuantity}
          </dd>

          <dt className="self-center text-gray-500 dark:text-gray-400">잔여 수량</dt>
          <dd
            className={`text-base font-bold ${
              remaining === 0
                ? 'text-red-600 dark:text-red-400'
                : 'text-indigo-600 dark:text-indigo-400'
            }`}
          >
            {remaining}
          </dd>
        </dl>
      )}
    </section>
  );
}
