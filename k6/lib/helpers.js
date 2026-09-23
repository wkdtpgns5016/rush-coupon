import http from 'k6/http';

// 부하 테스트 전용 쿠폰을 setup() 단계에서 만든다.
// 시드 쿠폰(수량 10)을 재사용하면 동시성 테스트 전에 재고가 바로 소진돼버려서,
// 매 실행마다 충분한 수량의 쿠폰을 새로 만들어 재고 소진이 아닌 락 경합 자체를 관찰한다.
export function createTestCoupon(baseUrl, quantity, title) {
  const now = Date.now();
  const payload = JSON.stringify({
    title,
    totalQuantity: quantity,
    startAt: new Date(now - 60 * 1000).toISOString(),
    endAt: new Date(now + 24 * 60 * 60 * 1000).toISOString(),
  });

  const res = http.post(`${baseUrl}/coupons`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'setup_create_coupon' },
  });

  if (res.status !== 201) {
    throw new Error(
      `테스트용 쿠폰 생성 실패 (setup): status=${res.status} body=${res.body}`,
    );
  }

  return res.json();
}
