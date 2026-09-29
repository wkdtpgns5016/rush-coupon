# [트러블슈팅] Worker 강제 종료 후 재배달 지연이 cleanup과 겹쳐 DLQ에 좀비 메시지 발생

## 요약

| 항목 | 내용 |
|---|---|
| 증상 | Worker 파드를 `--grace-period=0 --force`로 강제 종료하는 장애 테스트(#48) 직후엔 정합성이 완벽했는데(유실·중복 0), 약 2분 뒤 `coupon.issued.dlq`에 26건이 쌓임 |
| 원인 | RabbitMQ가 죽은 컨슈머의 커넥션을 하트비트 타임아웃(실측 108초)이 지나야 감지 — 그 사이 테스트 정리 스크립트(`cleanup.sql`)가 부모 쿠폰을 먼저 삭제해버려서, 뒤늦게 재배달된 메시지가 FK 위반으로 영구 실패 |
| 해결 | `k6/scripts/run.sh`에 RabbitMQ 메인/재시도 큐가 완전히 빌 때까지 기다리는 체크(`CHECK_RABBITMQ_DRAIN`) 추가 — Postgres row count만으로는 이 상황을 감지할 수 없어서 RabbitMQ 자체를 직접 확인하도록 함 |
| 소요 시간 | 약 1시간 (원인 규명에 대부분 소요, `kubectl get events`/CPU 쓰로틀링/네트워크 등 여러 후보를 배제해나가는 과정 포함) |

---

## 1. 배경

Issue #48 검증을 위해 baseline 부하를 걸며 Worker 파드 하나를 강제 종료(`kubectl delete pod --grace-period=0 --force`)한 뒤, `integrity-check.sql`로 저장 건수·중복·초과발급을 확인하는 테스트를 진행했다. `--grace-period=0 --force`는 SIGKILL로 즉시 종료시켜 `onModuleDestroy()`의 정상 종료 훅(마지막 flush)을 우회한다 — 일반 `kubectl delete pod`(SIGTERM)로는 이 훅이 먼저 실행돼 pending 배치를 곱게 정리하고 죽어버려서, "처리 중 갑자기 죽는" 상황 자체가 재현되지 않기 때문이다.

## 2. 증상

테스트 구간 자체는 완벽했다 — `integrity-check.sql`이 저장 건수 26,105 = 202 접수 26,105로 정확히 일치, 중복·초과발급 0건을 보고했다. 그런데 `cleanup.sql`로 테스트 데이터를 정리하고 **약 2분 뒤**, Worker 로그에 예상 밖의 에러가 몰아쳤다:

```
7:52:51 AM  ERROR [CouponIssueConsumerService] 배치 저장 실패 (13건) — 메시지별 x-death 이력에 따라 재시도 단계/DLQ로 라우팅
7:52:53 AM  ERROR ... 배치 저장 실패 (5건) ...
7:53:01 AM  ERROR ... 배치 저장 실패 (1건) ...
```

`rabbitmqctl list_queues name messages`로 확인하니 `coupon.issued.dlq`에 **26건**이 들어가 있었다.

## 3. 원인 규명 과정

### 3-1. 서버 인프라 문제부터 배제

```bash
kubectl get events -n rush-coupon --sort-by='.lastTimestamp' | grep -i backend
```
실패가 발생한 시간대(HOLD 구간 전체)에 파드 재시작·재스케줄·HPA 이벤트가 전혀 없었다. 파드 자체는 그 시간 내내 안정적이었다 — 인프라 문제는 아니었다.

### 3-2. 가설 수립과 반박

처음엔 "재시도 사다리(2s→8s→32s)를 거쳐서 DLQ에 도착했다"고 추정했으나, Grafana의 재시도 큐 패널(`coupon.retry.32s`)을 확인하니 해당 시간대 **Max가 0** — 재시도 큐를 거친 흔적이 없었다. DLQ 메시지의 `x-death` 헤더를 직접 까보려 했으나 이미 DLQ가 정리된 뒤라 확인하지 못했다(교훈: 조사가 끝나기 전엔 DLQ를 비우지 말 것).

### 3-3. 결정적 증거 — 큐 상태를 2초 간격으로 직접 기록

Prometheus의 15초 스크레이프 주기로는 짧은 상태 변화를 놓칠 수 있어서, 별도 터미널에서 직접 폴링했다:

```bash
while true; do date '+%H:%M:%S'; kubectl -n rush-coupon exec deploy/rabbitmq -- rabbitmqctl list_queues name messages; sleep 2; done
```

`coupon.issued`가 **특정 시각부터 108초 동안 정확히 고정된 값**을 유지하다가 한 번에 0으로 떨어지는 것을 확인했다. 이 108초가 RabbitMQ의 하트비트 타임아웃 — 죽은 컨슈머의 커넥션을 감지하는 데 걸리는 실제 시간이었다.

### 3-4. 메커니즘 정리

1. Worker가 SIGKILL로 죽을 때, 이미 Postgres에 커밋은 했지만 RabbitMQ에 **ack는 못 보낸** 메시지가 있었다.
2. RabbitMQ는 그 커넥션이 죽었다는 걸 하트비트 타임아웃(108초)이 지나야 알아챈다 — 그 전까지는 "누군가 처리 중"이라고 믿고 해당 메시지를 unacked로 계속 붙잡아 둔다.
3. 타임아웃이 지나면 RabbitMQ가 그 unacked 메시지들을 **자동으로 원래 큐(`coupon.issued`)에 재배달**한다. 이건 DLX 기반 재시도 사다리와는 다른, AMQP의 기본 "커넥션 종료 시 unacked 메시지 requeue" 메커니즘이라 `x-death` 헤더가 붙지 않는다.
4. 재배달된 메시지는 **이미 완료된 작업의 중복 재배달**이라 원래는 `.orIgnore()`(유니크 제약 `uq_coupon_user` 기반)가 조용히 무시했어야 한다.
5. 그런데 그 108초 사이에 **`run.sh`의 `cleanup.sql`이 이미 부모 쿠폰을 삭제**해버렸다. 재배달된 INSERT 시도는 `.orIgnore()`로는 막을 수 없는 **FK 제약 위반**으로 실패한다.
6. FK 위반은 "정상 처리 실패"로 분류돼 재시도 사다리로 라우팅되고, 부모 쿠폰이 영구히 없으므로 재시도해도 계속 실패해 최종적으로 DLQ에 격리된다.

**근본 원인**: 테스트 정리 스크립트(`run.sh`)의 "배출 완료" 판단이 Postgres `coupon_issues` row count 안정화만 보고 있었는데, 이 신호로는 이 상황을 원천적으로 감지할 수 없다 — 성공적으로 무시되는 중복 재배달은 row count에 아무 변화도 남기지 않기 때문이다.

## 4. 해결

`k6/scripts/run.sh`에 `CHECK_RABBITMQ_DRAIN` 옵트인 체크를 추가했다. 활성화 시 RabbitMQ **메인 큐(`coupon.issued`) + 재시도 큐(`coupon.retry.2s/8s/32s`) 합계가 0**이 될 때까지 폴링한 뒤에야 `latency-report.sql`/`integrity-check.sql`/`cleanup.sql`로 넘어간다.

```bash
CHECK_RABBITMQ_DRAIN=1 ./scripts/run.sh baseline
```

**DLQ는 의도적으로 대기 조건에서 제외했다** — DLQ에 쌓인 메시지는 이미 재시도를 다 거쳐 결론이 난 것이라 기다려도 없어지지 않고, DLQ 기준으로 기다리면 무관한 이유로 실패한 메시지 하나 때문에 정리 작업이 영원히 안 끝날 수 있다.

이 체크는 `latency-report.sql`/`integrity-check.sql`보다 **먼저** 실행되도록 배치했다 — 처음엔 순서가 반대라 이 두 리포트가 RabbitMQ 배출이 덜 끝난 중간 상태(실제보다 41건 적은 값)를 최종 결과처럼 보고하는 2차 버그가 있었고, 이것도 같이 고쳤다.

kubectl 의존성이 생기는 체크라 일반 baseline/spike/scaleout 실행에는 기본 비활성이다.

## 5. 재검증

동일한 강제 종료 시나리오를 수정된 파이프라인으로 재실행:

```
coupon.issued: 43건에서 108초간 고정 → 재배달 즉시 처리되며 0으로
coupon.retry.2s/8s/32s: 전 구간 0 (재시도 사다리를 타지 않음)
최종: 저장 건수 15,918 = 202 접수 15,918 = distinct_users 15,918
중복 0건, 초과발급 0건, DLQ 0건
```

이번엔 cleanup이 정확히 미뤄진 덕에 재배달 시점에 부모 쿠폰이 살아있었고, INSERT가 성공(또는 `.orIgnore()`로 조용히 무시)해 애초에 "실패"가 발생하지 않았다 — 그래서 재시도 로직 자체가 호출되지 않았다.

## 6. 참고 — Worker 강제 종료로는 재시도 사다리(DLX) 경로를 재현할 수 없다

이번 조사로 얻은 부가 발견: 재시도 큐(2s→8s→32s)는 "Worker가 처리를 시도했는데 그 시도 자체가 실패했을 때"만 탄다. Worker 강제 종료로 인한 재배달은 (부모 데이터가 살아있는 한) 항상 성공으로 끝나므로, 이 방식만으로는 재시도 사다리 경로를 검증할 수 없다. 그 경로를 테스트하려면 재배달 이후에도 저장이 실패하는 별도의 장애(예: Postgres 일시 장애)를 주입해야 한다.

## 관련 파일
- [k6/scripts/run.sh](../../k6/scripts/run.sh)
- [k6/scripts/integrity-check.sql](../../k6/scripts/integrity-check.sql)
- [m5-chaos-worker-failure-report.md](../load-test/m5-chaos-worker-failure-report.md) — 이 장애 시나리오의 전체 검증 리포트(#48)
