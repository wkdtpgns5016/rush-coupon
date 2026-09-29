// 재시도 큐(coupon.retry.2s/8s/32s)는 durable:true라 실제 RabbitMQ에 영구히 남는다.
// 여러 스펙 파일이 서로 다른 TTL로 같은 큐 이름을 선언하면 406(PRECONDITION_FAILED)이 난다
// (큐 인자는 한 번 정해지면 재선언 시 반드시 같아야 함) — 그래서 테스트 전역에서 이 값 하나로 통일한다.
export const TEST_RETRY_TTL_MS: readonly [number, number, number] = [
  Number(process.env.RETRY_TTL_2S_MS ?? 150),
  Number(process.env.RETRY_TTL_8S_MS ?? 200),
  Number(process.env.RETRY_TTL_32S_MS ?? 250),
];
