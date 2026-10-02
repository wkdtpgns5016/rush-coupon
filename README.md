# rush-coupon

대용량 트래픽 환경을 고려한 선착순 쿠폰 발급 시스템

비관적 락(SELECT ... FOR UPDATE) 기반 MVP로 시작해, 부하 테스트로 한계를 실측하고(M3), Valkey + RabbitMQ 기반 비동기 아키텍처로 전환한 뒤(M4) 동일한 조건으로 재검증했다(M5). 이 README는 그 전체 과정 — **무엇이 병목이었고, 왜 그 아키텍처를 골랐고, 실제로 얼마나 개선됐는지** — 를 정리한다.

---

## 1. M3 vs M5 성능 비교

같은 k6 시나리오(baseline/spike/scaleout)를 두 아키텍처에 동일하게 재실행한 결과다. 상세 수치·Grafana 캡처는 [M3 리포트](docs/load-test/m3-mvp-load-test-report.md), [M5 리포트](docs/load-test/m5-async-load-test-report.md)에 있다.

### 성공률 / 최대 replicas

| 시나리오 | M3 (비관적 락) | M5 (Valkey+RabbitMQ) | 비고 |
|---|---|---|---|
| baseline (10 VU, 1분) | 99.94% / 3 replicas | 100.00% / 10 replicas | 같은 VU 수인데 M5는 응답이 훨씬 빨라(20ms vs 300ms) closed-loop 특성상 실질 부하 자체가 커짐(27→401 RPS) |
| spike (3,000명 동시 발급) | 54.85% / 3 replicas | 99.97% / 3 replicas | M3는 60초 타임아웃 벽에 막혀 3분 내내 실패, M5는 4.4초 만에 전원 처리 완료(HPA가 반응할 새도 없었음) |
| scaleout (60 req/s, 11분, M3와 동일 조건) | 32.46% / 3 replicas | **100.00% / 2 replicas** | M3를 무너뜨린 부하를 M5는 최소 구성(2대)으로 무결점 처리 |
| scaleout (500 req/s, 11분, M5 확장성 검증용) | 측정 안 함 | 99.99 ~ 100.00% / 9 ~ 10 replicas | HPA 상한(max=10)에 처음으로 근접 — M5의 "다음 병목 후보" |

### API 응답 지연 (avg / p99) — 감소율

| 시나리오 | M3 avg / p99 | M5 avg / p99 | 감소율 |
|---|---|---|---|
| baseline | 299.5ms / 488.0ms | 20.5ms / 106.8ms | 93.2% / 78.1% ↓ |
| spike | 44,042.1ms / 59,822.7ms | 1,463.3ms / 3,522.7ms | 96.7% / 94.1% ↓ |
| scaleout (60rps) | 48,710.5ms / 60,002.4ms | 20.7ms / 114.7ms | 99.96% / 99.81% ↓ |

> scaleout의 500~2,300배 개선은 "M5가 엄청나게 빠르다"기보다 **"M3가 그 부하에서 완전히 막혀 있었다"**는 걸 반대로 보여주는 숫자로 읽는 게 정확하다. 전체 분위수(p50/p95/max)와 방법론 주의사항은 [M5 리포트 6-1절](docs/load-test/m5-async-load-test-report.md#6-1-수치로-본-개선폭) 참고.

**결론**: 병목은 사라진 게 아니라 자리를 옮겼다 — **DB 행 락 직렬화 → API 파드 HPA 상한/CPU 용량**. 500 req/s에서 레플리카가 9 ~ 10(상한 근접)까지 올라가고 CPU가 121 ~ 127%까지 튀는 걸 확인했는데, 이게 M5 아키텍처의 다음 확장 지점이다.

---

## 2. M6: 클라우드 마이그레이션

같은 아키텍처(Valkey+RabbitMQ)를 그대로 두고 인프라만 온프레미스(kubeadm VM + Tailscale)에서 관리형 클라우드(EKS + RDS + ElastiCache + Amazon MQ)로 옮긴 뒤, M3/M5와 동일한 k6 시나리오를 재실행해 3자 비교했다. 상세 수치·Grafana 캡처·의사결정 경위는 [M6 리포트](docs/load-test/m6-cloud-load-test-report.md)에 있다.

### 성공률 / 최대 replicas

| 시나리오 | M3 (비관적 락, 온프레미스) | M5 (Valkey+RabbitMQ, 온프레미스) | M6 (Valkey+RabbitMQ, 클라우드) |
|---|---|---|---|
| baseline (10 VU, 1분) | 99.94% / 3 | 100.00% / 10 | **100.00% / 4** |
| spike (3,000 VU) | 54.85% / 3 | 99.97% / 3 | **99.97% / 2 (스케일업 불필요)** |
| scaleout (60rps, 11분) | 32.46% / 3 | 100.00% / 2 | **100.00% / 2** |
| scaleout (500rps, 11분) | 측정 안 함 | 99.99 ~ 100.00% / 9 ~ 10 | **100.00% / 8** |

**결론**: 아키텍처 전환(M3→M5)의 개선폭이 인프라 전환(M5→M6)보다 훨씬 크다 — M5→M6는 이미 해소된 병목을 더 좋은 하드웨어/관리형 서비스로 옮긴 것이라 자릿수 차이는 안 난다. 다만 spike avg 지연(347ms vs M5 1,463ms)과 scaleout(500rps)의 레플리카 효율(8 vs 9~10)처럼, **M6가 M5보다 더 적은 자원으로 비슷하거나 더 안정적인 지연**을 보인 항목들이 있다 — EKS 노드의 코어당 처리 능력과 관리형 서비스(RDS/ElastiCache/Amazon MQ)의 네트워크 안정성이 온프레미스 VM 대비 높기 때문으로 보인다. M5에서 유일하게 재현 실패였던 500rps 1차의 일시적 지연 급증(원인 미확정)은 M6에서는 1차 시도에 재현되지 않았다. 세 환경 모두 DLQ 유실·정합성 오류 0건은 동일하다.

---

## 3. 아키텍처

```
사용자 요청
  → 백엔드가 Valkey에 재고/중복 판정 요청 (원자적 Lua EVAL)
  → 판정 통과 시 RabbitMQ에 발행 (publisher confirm 대기)
      ├─ 발행 성공 → 202 Accepted 즉시 응답
      └─ 발행 실패 → Valkey 예약 롤백 → 503 응답 ("유령 차감" 방지)
  → (비동기, 별도 파드) Worker가 큐를 구독해 메시지를 가져감
  → 배치로 모아 Postgres에 INSERT 시도
      ├─ 성공 → ack
      └─ 실패 → 재시도 큐(2s→8s→32s)로 재발행, 다 소진하면 DLQ 격리
```

| 구성 요소 | 역할 |
|---|---|
| Valkey | 재고 확인→차감→중복 확인을 Lua EVAL 하나로 원자 처리하는 "빠른 판정" 전용 |
| RabbitMQ | 큐잉·ack/nack·재시도(TTL+DLX)·DLQ — "안전한 전달과 영속화" 담당 |
| Worker | RabbitMQ consumer, 배치 INSERT로 PostgreSQL에 영속화(고정 2대, 오토스케일링 없음) |
| PostgreSQL | 최종 정합성 방어선(CHECK/UNIQUE/FK 제약) — [ERD](docs/domain/coupon-erd.md) |

### 아키텍처 결정 경위

1. **Redis 대신 Valkey**: 2024년 Redis가 BSD → SSPL/독점 라이선스로 전환하며 논란이 생겼고, 2025년 AGPLv3를 추가했지만 강한 카피레프트 조항 때문에 업계는 Valkey(BSD-3, Redis 완전 호환 포크)로 계속 이전 중. 프로토콜·Lua EVAL·클라이언트 모두 Redis와 호환된다.
2. **Valkey는 "판정"에만 쓴다**: 재고 확인→차감을 Lua EVAL 단일 연산으로 처리해 동시성 충돌을 원천 차단. 이 부분은 메시지 브로커로 대체 불가능한 영역이다.
3. **Valkey 단독안 폐기 → RabbitMQ 도입**: Valkey Stream + Sorted Set으로 재시도/DLQ까지 직접 구현하려 했으나, Lua로 개별 연산은 원자화해도 (1) 재시도 시점을 찾는 폴링 스케줄러를 직접 운영해야 하고 (2) Streams의 크래시 복구(PEL/`XCLAIM`)와 직접 만든 재시도 스케줄러가 서로 다른 메커니즘이라 상태 불일치 위험이 남는다. 이미 검증된 RabbitMQ의 TTL+DLX·재배달로 큐잉·재시도·DLQ를 분리했다(#48에서 무결성 확인).
4. **"판정"과 "처리"의 책임 분리**: Valkey(빠른 원자적 결정)와 RabbitMQ(안전한 전달·재시도·영속화)를 명확히 나눈 하이브리드 구조.

---

## 4. 트러블슈팅

실제로 값을 보면서 부딪힌 문제들이다. 전체 내용은 [`docs/troubleshooting/`](docs/troubleshooting/)에 있다.

| 문제 | 원인 | 해결 |
|---|---|---|
| [k8s 파드에서 Tailscale 너머 외부 Postgres 접속 실패](docs/troubleshooting/postgres-k8s-tailscale-routing.md) | Mac(Tailscale)-VM(k8s worker) 구성에서, Tailscale의 전용 라우팅 테이블이 **포워딩되는 트래픽에는 적용되지 않음** — subnet router(k8s-master)를 거쳐 나가는 파드 트래픽이 여기 해당 | k8s-worker 노드의 메인 라우팅 테이블에 `100.64.0.0/10 dev tailscale0` 라우트를 명시적으로 추가(systemd로 영구화). 원인 파악에만 약 2시간 소요 |
| [M3 spike 테스트에서 Grafana P95/P99가 실측값(59.8s)과 다르게 10s로 표시됨](docs/troubleshooting/grafana-histogram-bucket-precision.md) | `/metrics` 히스토그램 버킷이 100~500ms 구간 해상도라 그보다 큰 값을 담을 버킷이 없어 `histogram_quantile`이 최대 버킷으로 뭉개 추정 | 15/30/60/120s 버킷 추가 (#36), scaleout 재검증으로 확인 |
| [Worker 강제 종료 후 정리(cleanup) 스크립트가 DLQ에 좀비 메시지를 만듦](docs/troubleshooting/worker-kill-dlq-cleanup-race.md) | RabbitMQ가 죽은 컨슈머를 감지하는 데 하트비트 타임아웃(실측 **108초**)만큼 걸리는데, 그 사이 테스트 정리 스크립트가 부모 쿠폰을 먼저 삭제해버려 뒤늦게 재배달된 메시지가 FK 위반으로 영구 실패 | 정리 전 RabbitMQ 메인+재시도 큐가 완전히 빌 때까지 기다리는 체크 추가 (`CHECK_RABBITMQ_DRAIN`) |

**DLQ 운영**: 재시도(2s→8s→32s)를 다 소진한 메시지는 `coupon.issued.dlq`로 격리된다. 사람이 원인을 판단하고, 카나리아(`--limit`)로 소수만 먼저 되돌려 확인한 뒤 전체를 재발행하는 절차를 문서화했다 — [DLQ 복구 절차](docs/operations/dlq-recovery.md).

**Chaos 검증**: Worker를 `--grace-period=0 --force`(SIGKILL)로 강제 종료해도 RabbitMQ 재배달 + 배치 INSERT의 멱등성(`.orIgnore()` + `uq_coupon_user` 유니크 제약)으로 유실·중복·초과발급이 전부 0건임을 확인했다 — [Chaos 검증 리포트](docs/load-test/m5-chaos-worker-failure-report.md).

---

## 5. 프로젝트 구조

```
backend/    NestJS + TypeORM + PostgreSQL — 발급 API + Worker(같은 이미지, 엔트리포인트만 다름)
frontend/   선착순 발급 MVP UI
k6/         부하 테스트 시나리오(baseline/spike/scaleout) + 검증 스크립트
k8s/        모니터링(Grafana 대시보드) 등 애플리케이션 쪽 k8s 리소스
deploy/     외부 DB(Docker) 연동용 k8s 리소스
docs/       도메인 ERD, 설정 가이드, 부하 테스트 리포트, 트러블슈팅, 운영 절차
```

## 6. 실행 방법

- **클러스터 프로비저닝**: kubeadm 기반 k8s 클러스터(VM 2대) 생성과 모니터링 애드온(kube-prometheus-stack, metrics-server) 설치는 별도 레포 [setup-k8s-vm](https://github.com/wkdtpgns5016/setup-k8s-vm)의 스크립트를 사용했다.
- **신규 환경 세팅**: [docs/setup/fresh-environment-setup.md](docs/setup/fresh-environment-setup.md)
- **부하 테스트 (온프레미스)**: [docs/load-test/m5-k6-load-test.md](docs/load-test/m5-k6-load-test.md) (`k6/scripts/run.sh <baseline|spike|scaleout>`)
- **부하 테스트 (클라우드)**: `k6/scripts/run-cloud.sh <baseline|spike|scaleout>` — k6는 로컬에서 CloudFront 엔드포인트로 직접 실행하고, RDS 의존 후처리(배출 대기·정합성 검증·정리)는 자동으로 EKS 안의 일회성 Pod에서 수행한다(RDS가 private subnet이라 로컬에서 직접 접속 불가)
- **로컬 개발**: `cd backend && docker compose up -d`

## 7. 회고

- **비관적 락의 한계는 "직렬화"로 인한 병목 발생이였다.** M3에서 커넥션 풀과 CPU는 항상 여유가 있었는데도 처리량이 ~30 ops/s에서 못 움직였다 — 병목은 리소스가 아니라 락 자체의 순서 강제였다.
- **Valkey/RabbitMQ를 직접 다루며 AMQP 프로토콜의 구조를 체감할 수 있었다.** exchange-큐-라우팅 키 바인딩, publisher confirm, consumer ack/nack와 unacked 상태, TTL+DLX 기반 dead-lettering(x-death 헤더), 하트비트 기반 컨슈머 생존 감지(#48에서 108초로 직접 실측) 같은 개념들을 실제로 장애를 만들어 관찰하면서 깊이 이해 할수 있게 되었다.
- **Grafana/Prometheus는 순간 이벤트에 약하다.** 4초짜리 spike나 2초짜리 재시도 단계처럼 스크레이프 주기(15초)보다 짧은 현상은 과소평가되거나 아예 안 보이기 때문에 k6 자체 측정치, 또는 2초 간격 직접 폴링처럼 더 촘촘한 관측이 필요했다.

## 8. 향후 발전 과제

- **Worker 오토스케일링 부재**: 이번 테스트 범위(최대 큐 320건)에서는 고정 2대로 충분했지만, 오토스케일링이 없어 더 큰 지속 부하에서는 병목이 될 수 있다 — KEDA(큐 길이 기반) 도입
- **API 파드 HPA 상한**: `maxReplicas=10`이 500 req/s에서 이미 근접했다 — 더 큰 트래픽을 감당하려면 상한 조정 필요
- **RabbitMQ 하트비트 미설정**: `amqplib.connect()`에 명시 안 해서 서버 기본값(60초, 감지 최대 120초)에 의존 중이다 — 더 빠른 장애 감지가 필요하면 해당 설정 값을 조정
- **Amazon MQ 큐 깊이 관측 공백 (M6)**: self-hosted RabbitMQ와 달리 Amazon MQ는 ServiceMonitor가 스크랩할 Pod가 없어 Grafana 큐 패널이 "No data"다 — 필요해지면 CloudWatch 지표를 Grafana 데이터소스로 추가하거나 Amazon MQ API를 직접 폴링해야 한다
- **클라우드에서도 500 req/s가 HPA 상한에 근접 (M6)**: `maxReplicas=10` 중 8까지 썼다 — 더 큰 트래픽을 감당하려면 온프레미스와 마찬가지로 상한 조정이나 파드 리소스 튜닝이 필요하다
