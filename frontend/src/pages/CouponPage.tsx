import { useCallback, useEffect, useState } from 'react';
import { ApiError, getCoupon, issueCoupon, type Coupon } from '../api/coupons';
import { CouponInfo } from '../components/CouponInfo';
import { IssueForm } from '../components/IssueForm';

const COUPON_ID = import.meta.env.VITE_DEFAULT_COUPON_ID ?? '1';

type Feedback = { type: 'success' | 'error'; text: string };

const ERROR_MESSAGES: Record<string, string> = {
  SOLD_OUT: '쿠폰이 모두 소진되었습니다.',
  INVALID_PERIOD: '발급 가능한 기간이 아닙니다.',
  DUPLICATE: '이미 발급받은 쿠폰입니다.',
};

export function CouponPage() {
  const [coupon, setCoupon] = useState<Coupon | null>(null);
  const [isLoadingCoupon, setIsLoadingCoupon] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [userId, setUserId] = useState('1001');
  const [isIssuing, setIsIssuing] = useState(false);
  const [feedback, setFeedback] = useState<Feedback | null>(null);

  const loadCoupon = useCallback(async () => {
    try {
      const data = await getCoupon(COUPON_ID);
      setCoupon(data);
      setLoadError(null);
    } catch (err) {
      setLoadError(
        err instanceof ApiError
          ? err.message
          : '쿠폰 정보를 불러오지 못했습니다.',
      );
    } finally {
      setIsLoadingCoupon(false);
    }
  }, []);

  useEffect(() => {
    let ignore = false;

    (async () => {
      try {
        const data = await getCoupon(COUPON_ID);
        if (ignore) return;
        setCoupon(data);
        setLoadError(null);
      } catch (err) {
        if (ignore) return;
        setLoadError(
          err instanceof ApiError
            ? err.message
            : '쿠폰 정보를 불러오지 못했습니다.',
        );
      } finally {
        if (!ignore) setIsLoadingCoupon(false);
      }
    })();

    return () => {
      ignore = true;
    };
  }, []);

  const handleRefresh = () => {
    setIsLoadingCoupon(true);
    loadCoupon();
  };

  const handleIssue = async () => {
    if (isIssuing || !coupon || coupon.totalQuantity - coupon.issuedQuantity <= 0) {
      return;
    }

    setIsIssuing(true);
    setFeedback(null);
    try {
      const result = await issueCoupon(COUPON_ID, userId);
      setCoupon((prev) =>
        prev ? { ...prev, issuedQuantity: prev.issuedQuantity + 1 } : prev,
      );
      setFeedback({
        type: 'success',
        text: `쿠폰이 발급되었습니다! (발급 시각: ${new Date(result.issuedAt).toLocaleString()})`,
      });
    } catch (err) {
      const text =
        err instanceof ApiError
          ? (ERROR_MESSAGES[err.kind] ?? '오류가 발생했습니다.')
          : '오류가 발생했습니다.';
      setFeedback({ type: 'error', text });
    } finally {
      setIsIssuing(false);
    }
  };

  const remaining = coupon ? coupon.totalQuantity - coupon.issuedQuantity : 0;

  return (
    <div className="min-h-svh bg-gray-50 px-4 py-10 dark:bg-gray-900">
      <div className="mx-auto flex w-full max-w-md flex-col gap-5">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">
          선착순 쿠폰 발급
        </h1>
        <CouponInfo
          coupon={coupon}
          loading={isLoadingCoupon}
          error={loadError}
          onRefresh={handleRefresh}
        />
        <IssueForm
          userId={userId}
          onUserIdChange={setUserId}
          onIssue={handleIssue}
          isIssuing={isIssuing}
          remaining={remaining}
          feedback={feedback}
        />
      </div>
    </div>
  );
}
