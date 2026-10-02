# M6 클라우드 인프라 부하테스트 리포트 (M3 vs M5 vs M6)

## 요약

| 항목 | 내용 |
|---|---|
| 범위 | Issue #60 — M3/M5와 동일한 k6 시나리오(baseline/spike/scaleout)를 클라우드 인프라(EKS+RDS+ElastiCache+Amazon MQ) 대상으로 재실행, 3자 비교 |
| 측정일 | 2026-10-02 |
| 대상 | EKS(`rush-coupon-cloud`), API HPA `min=2 max=10`, Worker 고정 2대 — 애플리케이션 아키텍처는 M5와 동일(Valkey+RabbitMQ), 인프라만 온프레미스 → 관리형 클라우드로 교체 |
| 결론 | 같은 아키텍처(M5)를 관리형 클라우드로 옮긴 결과 **처리량/지연 모두 M5와 같은 수준이거나 더 나았다** — baseline avg 22.5ms, spike 성공률 99.97%, scaleout(60rps) 100%, scaleout(500rps) 100%. M5에서 보였던 "500rps에서 HPA가 상한 근접"은 M6에서는 replicas 7~8로 더 여유 있게 처리됐다 |
| 관련 파일 | [run-cloud.sh 실행 방법](../../k6/scripts/run-cloud.sh), [results/m6/](results/m6/) (Grafana 캡처), [m3 리포트](m3-mvp-load-test-report.md), [m5 리포트](m5-async-load-test-report.md) |

---

## 1. baseline (10 VU, 1분)

```
총 요청 수: 22,023
RPS (k6 평균): 365.77
API 응답 지연: avg=22.5ms / p95=39.7ms / p99=106.3ms / max=218.6ms
네트워크 레벨 실패율: 0.00%
발급 접수 성공(202): 22,022건 (100.00%)
종단 지연(큐 적재→Worker 저장 완료): avg=120.7ms / p50=108.2ms / p95=268.4ms / p99=404.6ms / max=506.0ms
```

Grafana에서 관찰된 점:
- 레플리카가 2 → 4까지 올라갔다(M5는 10까지, M3는 3까지). 같은 10 VU라도 세 환경의 인스턴스 스펙·CPU request가 달라 레플리카 수 자체를 동일 잣대로 비교하긴 어렵다 — 중요한 건 셋 다 **HPA가 의도대로 반응했고 요청을 전부 처리했다**는 점이다.
- 최대 CPU 사용률(requests 대비) 98.3%, RabbitMQ 연동 계층은 baseline 수준에서 문제없이 소화됨.

캡처: [http](results/m6/baseline-20261002-1434-http.png) · [hpa](results/m6/baseline-20261002-1434-hpa.png) · [db](results/m6/baseline-20261002-1434-db.png) · [issue-result](results/m6/baseline-20261002-1434-issue-result.png) · [queue](results/m6/baseline-20261002-1434-queue.png)

## 2. spike (3,000 VU, 각 1회 요청)

```
총 요청 수: 3,001
RPS (k6 평균): 230.33
API 응답 지연: avg=347.1ms / p95=1,686.1ms / p99=2,982.4ms / max=4,626.5ms
네트워크 레벨 실패율: 0.00%
발급 접수 성공(202): 3,000건 (99.97%)
종단 지연: avg=93.9ms / p50=60.9ms / p95=372.1ms / p99=496.1ms / max=511.1ms
```

M5와 성공률은 동일(99.97%)하지만 API 응답 지연은 M6가 더 크게 나왔다(p99 2,982.4ms vs M5 3,522.7ms — 오히려 M6가 조금 낮음, avg는 347.1ms vs 1,463.3ms로 M6가 더 빠름). HPA는 3,000명이 순간적으로 몰렸는데도 **레플리카가 2에서 전혀 늘지 않았다**(M3/M5는 둘 다 3까지 반응) — 클라우드 인스턴스의 CPU 여유가 더 커서 스케일업 자체가 필요 없었던 것으로 보인다.

캡처: [http](results/m6/spike-20261002-1450-http.png) · [hpa](results/m6/spike-20261002-1450-hpa.png) · [db](results/m6/spike-20261002-1450-db.png) · [issue-result](results/m6/spike-20261002-1450-issue-result.png) · [queue](results/m6/spike-20261002-1450-queue.png)

## 3. scaleout — M3/M5와 동일 조건 (60 req/s, 11분)

```
총 요청 수: 34,200 / 목표 34,200 (100% 완주)
RPS (k6 평균): 51.88
API 응답 지연: avg=26.8ms / p95=94.9ms / p99=106.0ms / max=365.0ms
네트워크 레벨 실패율: 0.00%
발급 접수 성공(202): 34,199건 (100.00%)
종단 지연: avg=255.8ms / p50=254.9ms / p95=480.5ms / p99=501.5ms / max=513.5ms
```

M5와 마찬가지로 레플리카가 2(최소값)에 고정된 채 11분간 무결점으로 처리됐다 — 60 req/s는 M5/M6 아키텍처 모두에게 트리비얼한 수준이라는 결론이 클라우드에서도 재확인됐다.

캡처: [http](results/m6/scaleout-20261002-1512-r60-http.png) · [hpa](results/m6/scaleout-20261002-1512-r60-hpa.png) · [db](results/m6/scaleout-20261002-1512-r60-db.png) · [issue-result](results/m6/scaleout-20261002-1512-r60-issue-result.png) · [queue](results/m6/scaleout-20261002-1512-r60-queue.png)

## 4. scaleout — HPA 선형 확장성 검증 (500 req/s, 11분)

M5의 4번 절과 동일한 목적(HPA 확장 곡선 관찰)으로 500 req/s를 11분간 유지했다. M5는 두 번 실행해야 했지만(1차에서 원인 불명의 일시적 지연 급증 발생), M6는 **1차 실행만으로 지연 급증 없이 깨끗하게 끝났다**.

```
총 요청 수: 285,000 / 목표 285,000 (100% 완주)
RPS (k6 평균): 431.73
API 응답 지연: avg=31.2ms / p95=100.6ms / p99=112.4ms / max=452.6ms
네트워크 레벨 실패율: 0.00%
발급 접수 성공(202): 284,999건 (100.00%)
종단 지연: avg=101.5ms / p50=90.8ms / p95=224.6ms / p99=360.7ms / max=509.8ms
```

| 지표 | M5 1차 (15:05, 이상 발생) | M5 2차 (15:36, 재현 안 됨) | M6 (16:16, 1회) |
|---|---|---|---|
| 목표 대비 완주 | 257,458 / 285,000 (90%) | 285,000 / 285,000 (100%) | **285,000 / 285,000 (100%)** |
| 성공률 | 99.99% | 100.00% | **100.00%** |
| API 응답 max | 33,993.9ms | 421.6ms | **452.6ms** |
| 종단 지연 max | 58,946.1ms | 532.7ms | **509.8ms** |
| 최대 replicas | 10 | 9 | **8** |
| 최대 CPU | 127% | 121% | **132%** |

레플리카는 M5(9~10)보다 적은 **8대**로, 더 높은 최대 CPU(132%)를 감수하면서도 지연은 더 안정적으로(p99 112.4ms, M5 2차의 p99 152.5ms보다 낮음) 처리했다 — 같은 HPA 설정(`max=10`)이라도 클라우드 인스턴스 타입의 코어당 처리 능력이 더 높아 같은 부하에 필요한 레플리카 수 자체가 줄어든 것으로 해석된다. 500 req/s는 M6에서도 여전히 HPA 상한(10)에 근접하는 수준(8/10)이라, "다음 병목 후보가 API 파드의 HPA 상한"이라는 M5의 결론은 클라우드에서도 유효하다.

캡처: [http](results/m6/scaleout-20261002-1616-r500-http.png) · [hpa](results/m6/scaleout-20261002-1616-r500-hpa.png) · [db](results/m6/scaleout-20261002-1616-r500-db.png) · [issue-result](results/m6/scaleout-20261002-1616-r500-issue-result.png) · [queue](results/m6/scaleout-20261002-1616-r500-queue.png)

## 5. 메시지 큐 패널 — "No data" (측정 한계)

M3/M5는 self-hosted RabbitMQ의 `rabbitmq_prometheus` 플러그인을 ServiceMonitor가 직접 스크랩해서 큐별 길이 추이를 그렸다([`k8s/monitoring/README.md`](https://github.com/wkdtpgns5016/rush-coupon-deploy/blob/main/k8s/monitoring/README.md) 참고). M6는 Amazon MQ(관리형 RabbitMQ)를 쓰는데, Amazon MQ는 Kubernetes Pod가 아니라 AWS가 운영하는 브로커라 **ServiceMonitor가 스크랩할 대상 자체가 없다** — 그래서 "큐 길이 추이" 패널은 전 시나리오에서 "No data"로 나온다("DLQ 길이"/"메인 처리 큐 길이" 현재값 타일은 0으로 보이는데, 이는 값이 없을 때 0으로 떨어지는 stat 패널 기본 동작일 뿐 실제 관측치가 아니다).

---

## 6. 종합 비교 (M3 vs M5 vs M6)

### 성공률 / 최대 replicas

| 시나리오 | M3 (비관적 락, 온프레미스) | M5 (Valkey+RabbitMQ, 온프레미스) | M6 (Valkey+RabbitMQ, 클라우드) |
|---|---|---|---|
| baseline (10 VU, 1분) | 99.94% / 3 | 100.00% / 10 | **100.00% / 4** |
| spike (3,000 VU) | 54.85% / 3 | 99.97% / 3 | **99.97% / 2 (스케일업 불필요)** |
| scaleout (60rps, 11분) | 32.46% / 3 | 100.00% / 2 | **100.00% / 2** |
| scaleout (500rps, 11분) | 측정 안 함 | 99.99~100.00% / 9~10 | **100.00% / 8** |

### API 응답 지연 (avg / p99)

| 시나리오 | M3 | M5 | M6 |
|---|---|---|---|
| baseline | 299.5ms / 488.0ms | 20.5ms / 106.8ms | **22.5ms / 106.3ms** |
| spike | 44,042.1ms / 59,822.7ms | 1,463.3ms / 3,522.7ms | **347.1ms / 2,982.4ms** |
| scaleout (60rps) | 48,710.5ms / 60,002.4ms | 20.7ms / 114.7ms | **26.8ms / 106.0ms** |
| scaleout (500rps) | — | 36.3ms / 152.5ms (2차 기준) | **31.2ms / 112.4ms** |

### 해석

**아키텍처 전환(M3→M5)의 개선폭이 인프라 전환(M5→M6)의 개선폭보다 압도적으로 크다.** M3→M5는 비관적 락 직렬화를 제거해 처리량 상한(~30 ops/s) 자체를 없앴지만, M5→M6는 이미 같은 아키텍처를 더 좋은 하드웨어/관리형 서비스로 옮긴 것이라 수치 차이가 같은 자릿수 안에서 난다 — 오히려 spike avg(347ms vs 1,463ms)와 scaleout(500rps)의 레플리카 효율(8 vs 9~10)처럼 **M6가 M5보다 더 적은 자원으로 비슷하거나 더 안정적인 지연**을 보인 항목들이 있다. 이는 EKS의 노드 인스턴스 타입이 온프레미스 VM(VirtualBox)보다 코어당 처리 능력이 높고, RDS/ElastiCache/Amazon MQ 같은 관리형 서비스가 온프레미스 자체 구축 대비 네트워크 경로가 더 안정적이기 때문으로 보인다.

**바뀌지 않은 것**: 세 환경 모두 DLQ 유실 0건, 정합성 검증(중복/초과 발급) 0건 — M4에서 도입한 Valkey(원자적 판정)+RabbitMQ(재시도/DLQ) 설계의 정합성 보장은 인프라가 바뀌어도 그대로 유지된다는 걸 확인했다.

---

## 7. 의사결정 경위 (DB 자격증명 관리)

DB 자격증명 관리: Terraform 직접 관리 → ArgoCD PreSync Hook Job, IRSA → EKS Pod Identity. 완전히 빈 환경에서 처음부터 검증하는 과정에서 겪은 문제 5가지와 각각의 원인·해결·교훈은 [db-credentials-presync-hook-and-pod-identity.md](../troubleshooting/db-credentials-presync-hook-and-pod-identity.md) 참고.

---

## 8. 향후 발전 과제

- **Amazon MQ 큐 깊이 관측 공백**: Prometheus/Grafana로는 못 보므로, 필요해지면 CloudWatch 지표(`QueueSize` 등)를 Grafana 데이터소스로 추가하거나 Amazon MQ의 관리 콘솔/API를 직접 폴링하는 보완이 필요하다.
- **500 req/s에서 HPA 상한 근접은 클라우드에서도 동일**: `maxReplicas=10`이 8/10까지 쓰였다 — 더 큰 트래픽을 감당하려면 M5와 마찬가지로 상한 조정이나 파드 리소스 튜닝이 필요하다.
