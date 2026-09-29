# [운영] DLQ(coupon.issued.dlq) 복구 절차

배치 저장이 계속 실패해 재시도 사다리(2s→8s→32s)를 전부 소진한 메시지는 `coupon.issued.dlq`로 격리된다.
이 문서는 그 이후 — 원인을 어떻게 판단하고, 어떻게 안전하게 되돌리는지 — 를 다룬다.

## 1. 먼저 확인할 것 — DLQ에 쌓였다는 걸 어떻게 아는가

- Grafana "Rush Coupon API" 대시보드의 **메시지 큐 (RabbitMQ 재시도 / DLQ)** 행에서 "DLQ 길이 (현재)" 패널이 0보다 크면 격리된 메시지가 있다는 뜻이다.
- 직접 확인:
  ```bash
  kubectl -n rush-coupon exec deploy/rabbitmq -- rabbitmqctl list_queues name messages
  ```

## 2. 원인이 해결됐는지 판단하기 (사람이 직접 해야 함)

`requeue-dlq.js`는 "DLQ에 있는 걸 원래 큐로 되돌리는" 동작만 할 뿐, **원인이 해결됐는지는 절대 판단해주지 않는다.** 자동으로 주기적 재발행을 돌리면 안 되는 이유도 이것이다 — 원인이 안 고쳐진 상태로 돌리면 backlog 전체가 또 실패해서 DLQ로 돌아오고, 그걸 또 자동으로 돌리는 무한 루프가 된다. DLQ가 존재하는 이유 자체(사람이 볼 때까지 격리)가 무의미해진다.

판단에 쓸 수 있는 신호:

1. **의심되는 원인 자체를 직접 확인** — DB 장애였다면 DB가 다시 붙는지, RabbitMQ 파드 재시작이었다면 다시 `Running`으로 안정됐는지
   ```bash
   kubectl -n rush-coupon get pods
   ```
2. **Worker 로그로 "지금 들어오는 새 메시지"가 정상 처리되는지 확인** — DLQ에 있는 옛날 메시지가 아니라, 현재 실시간으로 처리 중인 것들이 성공하고 있는지가 중요하다
   ```bash
   kubectl -n rush-coupon logs deploy/worker --tail=50 -f
   # "배치 저장 실패"가 최근엔 안 찍히고 "N건 배치 저장 완료"만 찍히는지
   ```
3. DLQ 길이가 더 이상 늘지 않고 안정된 상태인지 (Grafana "큐 길이 추이" 패널)

## 3. 카나리아 테스트 — 소수만 먼저 되돌리기

원인 해결 판단이 틀렸을 경우의 피해를 줄이기 위해, 전체를 한 번에 되돌리지 않고 **1~2건만 먼저** 되돌려서 확인한다.

```bash
# 몇 건 있는지만 먼저 확인 (아무것도 옮기지 않음)
kubectl -n rush-coupon exec deploy/worker -- node dist/scripts/requeue-dlq.js --dry-run

# 1~2건만 먼저 되돌려본다
kubectl -n rush-coupon exec deploy/worker -- node dist/scripts/requeue-dlq.js --limit 2
```

Worker 로그로 그 메시지들이 이번엔 정상 처리됐는지 확인한다:

```bash
kubectl -n rush-coupon logs deploy/worker --tail=20
```

- **"N건 배치 저장 완료"**가 찍히면 성공 → 4번으로 진행
- **"배치 저장 실패"**가 또 찍히면 원인이 아직 안 고쳐진 것 → 여기서 멈추고 재진단. (참고: 재발행된 메시지는 기존 x-death 헤더를 그대로 들고 가므로, 실패하면 재시도 사다리를 다시 밟지 않고 곧장 DLQ로 재격리된다 — 의도된 동작이다.)

## 4. 나머지 전체 재발행

카나리아 테스트가 성공했으면 `--limit` 없이 나머지를 마저 되돌린다.

```bash
kubectl -n rush-coupon exec deploy/worker -- node dist/scripts/requeue-dlq.js
```

## 5. 마무리 확인

```bash
kubectl -n rush-coupon exec deploy/rabbitmq -- rabbitmqctl list_queues name messages
# coupon.issued.dlq 가 0이어야 함
```

Grafana "DLQ 길이 (현재)" 패널이 0으로 돌아오는지도 함께 확인한다.
