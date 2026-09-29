# M5 Worker 장애 시나리오 — 데이터 무결성 및 복원력(Chaos) 검증 리포트

## 요약

| 항목 | 내용 |
|---|---|
| 범위 | Issue #48 — Worker 강제 종료 시 RabbitMQ 재배달과 배치 INSERT 멱등성이 실제로 유실·중복 없이 동작하는지 검증 |
| 측정일 | 2026-09-29 |
| 방법 | `k6 baseline` 부하를 걸며 Worker 파드 하나를 `kubectl delete pod --grace-period=0 --force`로 즉시 종료(SIGKILL, graceful shutdown 훅 우회) |
| 결론 | **유실 0건, 중복 0건, 초과발급 0건** — 멱등성(`.orIgnore()` + `uq_coupon_user`)이 실제 장애에서도 작동함을 확인 |
| 관련 파일 | [m5-k6-load-test.md](m5-k6-load-test.md), [k6/scripts/integrity-check.sql](../../k6/scripts/integrity-check.sql), [k6/scripts/run.sh](../../k6/scripts/run.sh), [트러블슈팅: Worker 강제 종료 후 재배달 지연이 cleanup과 겹쳐 DLQ에 좀비 메시지 발생](../troubleshooting/worker-kill-dlq-cleanup-race.md) |

---

## 1. 테스트 방법

1. 한 터미널에서 `CHECK_RABBITMQ_DRAIN=1 ./scripts/run.sh baseline`로 부하 시작 (10 VU, 1분)
2. 부하 도중 다른 터미널에서 Worker 파드 하나를 강제 종료:
   ```bash
   kubectl -n rush-coupon delete pod <worker-pod> --grace-period=0 --force
   ```
   `--grace-period=0 --force`는 SIGKILL로 즉시 종료시켜 `onModuleDestroy()`의 정상 종료 훅(마지막 flush)을 우회한다 — 일반 `kubectl delete pod`(SIGTERM)로는 이 훅이 먼저 실행돼 pending 배치를 곱게 정리하고 죽어버려서, "처리 중 갑자기 죽는" 상황 자체가 재현되지 않는다.
3. 종료 후 남은/신규 Worker 파드가 자동으로 큐를 이어받는지, RabbitMQ 큐 상태가 어떻게 움직이는지 관찰
4. 테스트 종료 후 `k6/scripts/integrity-check.sql`로 저장 건수·중복·초과발급 검증

## 2. 1차 시도에서 발견된 문제

첫 강제 종료 테스트 자체는 정합성 문제가 없었지만(저장 건수 26,105 = 202 접수 26,105 정확히 일치, 중복·초과발급 0건), 정리(cleanup) 후 약 2분 뒤 `coupon.issued.dlq`에 좀비 메시지 26건이 쌓이는 부작용이 발견됐다. 원인은 애플리케이션 코드가 아니라 테스트 도구(`run.sh`)의 정리 타이밍이 RabbitMQ의 장애 감지 지연과 경합한 레이스 컨디션이었다.

원인 규명 과정과 수정 내용은 별도 문서에 정리했다 → **[[트러블슈팅] Worker 강제 종료 후 재배달 지연이 cleanup과 겹쳐 DLQ에 좀비 메시지 발생](../troubleshooting/worker-kill-dlq-cleanup-race.md)**

수정 요지: `k6/scripts/integrity-check.sql` 신규 작성(저장 건수/중복/초과발급 검증), `k6/scripts/run.sh`에 `CHECK_RABBITMQ_DRAIN` 옵트인 체크 추가(RabbitMQ 메인+재시도 큐가 완전히 빌 때까지 cleanup을 미룸, DLQ는 제외).

## 3. 재검증 — 수정 후 완전한 성공 + 하트비트 지연 실측

수정한 파이프라인으로 baseline 부하 + Worker 강제 종료를 다시 실행했다. 옆 터미널에서 2초 간격으로 큐 상태를 직접 기록한 결과, `coupon.issued`가 **정확히 108초 동안 43건에 고정**돼 있다가 한 번에 0으로 떨어졌다(RabbitMQ가 죽은 컨슈머의 커넥션을 하트비트 타임아웃으로 감지하는 데 걸린 실측 시간). 그 전체 구간 동안 재시도 큐(`coupon.retry.2s/8s/32s`)는 단 한 번도 0을 벗어나지 않았다 — 자세한 해석은 위 트러블슈팅 문서 참고.

최종 결과:
```
총 요청 수: 15,919 / 202 접수: 15,918
저장 건수(persisted_count): 15,918
distinct_users: 15,918
중복 발급: 0건, 초과 발급: 0건
DLQ: 0건
```

## 4. 수정 전/후 비교

| 항목 | 1차 (수정 전) | 재검증 (수정 후) |
|---|---|---|
| 테스트 구간 내 유실·중복 | 0건 (원래도 정상) | 0건 |
| 정리 후 DLQ 좀비 메시지 | **26건** | **0건** |
| latency-report.sql/integrity-check.sql 정확도 | 중간 스냅샷을 최종 결과로 오보 | 최종 상태 정확히 반영 |
| RabbitMQ 하트비트 감지 지연 | 미측정(추정 ~2분) | **108초 (직접 실측)** |

## 5. #48 결론

- ✅ **RabbitMQ 재배달 + `.orIgnore()`/`uq_coupon_user` 기반 멱등성**이 실제 Worker 강제 종료 상황에서 유실·중복 없이 작동함을 두 차례 실측으로 확인했다.
- ✅ **발급 수량 정합성**(Valkey 판정 통과 건수 = DB 저장 건수)이 장애 상황에서도 정확히 일치했다.
- ✅ **DLQ 오격리 문제를 발견하고 수정했다**(트러블슈팅 문서 참고) — 프로덕션에서는 쿠폰을 이렇게 즉시 삭제하지 않으므로 실사용 시나리오에는 영향이 없지만, "Worker 장애 후 정리 작업은 RabbitMQ의 장애 감지 지연(이번 환경 실측 108초)보다 충분히 나중에 해야 한다"는 운영 인사이트를 남겼다.
- 🔍 **Worker 강제 종료만으로는 재시도 사다리(DLX) 경로를 재현할 수 없다**는 것도 확인했다 — 이 경로를 검증하려면 별도의 DB 장애 주입 시나리오가 필요하며, 이번 이슈 범위 밖으로 남겨둔다.
