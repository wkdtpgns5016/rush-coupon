# k8s/monitoring

rush-coupon **애플리케이션 쪽** 모니터링 리소스입니다. Prometheus/Grafana 자체(kube-prometheus-stack)와 metrics-server는
[setup-k8s-vm](https://github.com/wkdtpgns5016/setup-k8s-vm)의 `install-addons.sh`가 설치합니다.

| 무엇 | 어디 | 적용 방식 |
|---|---|---|
| backend `/metrics` 수집 (ServiceMonitor, 15s) | `k8s/backend/base/servicemonitor.yaml` | ArgoCD `backend` Application이 자동 적용 |
| backend HPA (2~10, CPU 70% / 메모리 80%) | `k8s/backend/base/hpa.yaml` | ArgoCD가 자동 적용 |
| PostgreSQL 지표 수집 (postgres-exporter + ServiceMonitor, 15s) | `k8s/backend/base/postgres-exporter/` | ArgoCD `backend` Application이 자동 적용 |
| Grafana 대시보드 "Rush Coupon API" | `k8s/monitoring/dashboards/rush-coupon-api.json` | 아래 `kubectl apply -k` (ArgoCD 추적 대상 아님) |

## 대시보드 적용

```bash
kubectl apply -k k8s/monitoring
```

Grafana 사이드카가 잠시 뒤 자동으로 읽습니다. 대시보드는 프로비저닝이라 UI에서 수정해도 저장되지 않으니, 고칠 때는 JSON을 수정한 뒤 다시 apply 합니다.

## 대시보드 구성 (부하 테스트 분석용)

분석 흐름 순서로 배치했습니다. **시간 범위를 테스트 구간으로 맞추면** 위쪽 "테스트 요약"이 그 구간의 총량·최댓값을 보여 줍니다.

| 행 | 답하는 질문 | 주요 패널 |
|---|---|---|
| 테스트 요약 | 목표를 달성했나 | 총 요청 수, 평균/최대 RPS, 5xx 오류율, 최대 P95/P99, 최대 replicas, 최대 CPU 사용률 |
| 처리량 vs 지연 | 어디서 한계가 왔나 | RPS와 P99 겹침(처리량이 안 오르는데 P99만 치솟는 지점이 한계), P50/P95/P99, 상태코드별 RPS, 4xx/5xx 오류율 |
| 오토스케일링 | 스케일링이 제때 됐나 | replicas, CPU 사용률(Pod별 + HPA 기준 평균), CPU 쓰로틀링, Pending Pod |
| 데이터베이스 | 병목이 DB인가 | 락 대기 세션, 커넥션 사용률, TPS, 캐시 적중률, 세션 상태, 행 처리량, 데드락 |
| 쿠폰 발급 결과 | 정합성이 지켜졌나 | 201/400/409/5xx 분포와 전환 시점 |
| 부하 분산 (접힘) | 특정 Pod로 쏠렸나 | Pod별 RPS, Pod별 P99 |
| 노드 · 네트워크 (접힘) | 노드가 막았나 | 노드 CPU/메모리, Pod 네트워크 |

## PostgreSQL 지표 (postgres-exporter)

- DB는 클러스터 밖(Docker)에 있지만 backend와 같은 경로(`postgres-service`)로 접속하고, **backend가 쓰는 시크릿 `backend-db-credentials`를 그대로 재사용**합니다. 별도의 DB 작업은 필요 없습니다.
  이 환경에서는 앱 계정이 `POSTGRES_USER`(Docker 이미지에서 슈퍼유저)라 모든 통계가 보입니다. 운영에서는 `pg_monitor` 권한만 가진 전용 계정을 만들어 시크릿을 분리하세요.
- 부하 테스트에 필요한 수집기만 켰습니다(`stat_database`, `stat_activity`, `stat_user_tables`, `long_running_transactions`, 기본 `locks`/`settings`/`database`). 나머지는 꺼서 스크레이프마다 DB에 던지는 쿼리와 시계열 수를 줄였습니다(메모리 약 4MiB).
- **락 대기**는 `pg_stat_activity_count{wait_event_type="Lock"}`로 봅니다. 선착순 발급은 쿠폰 한 행을 `SELECT ... FOR UPDATE`로 잠그므로 `wait_event=tuple`/`transactionid`가 대기열입니다. 같은 행에 50개 세션이 몰리게 재현해서 49개 대기로 나오는 것을 확인했습니다.
- 커넥션 사용률은 `pg_settings_max_connections`(이 저장소 `postgresql.conf`는 300)가 분모입니다.

## 히스토그램 버킷

`http_request_duration_seconds` 버킷은 `5, 10, 25, 50, 75, 100, 150, 200, 300, 500, 750ms, 1, 2.5, 5, 10s`입니다. P95/P99가 100~500ms 구간에 놓이기 쉬워서 이 구간을 촘촘히 했습니다. 버킷을 바꾼 이미지를 롤링 배포하는 동안에는 옛 Pod와 새 Pod의 버킷이 섞여 **그 몇 분 동안만** 분위수가 어긋날 수 있습니다.

## 적용 순서

`backend` Application이 ServiceMonitor(CRD)와 HPA(metrics-server)를 함께 적용하므로 **모니터링 애드온이 먼저** 설치되어 있어야 합니다.
그렇지 않으면 ArgoCD 동기화가 `no matches for kind "ServiceMonitor"`로 실패하거나, HPA가 `<unknown>` 메트릭 상태로 남습니다.

## 설치 후 확인

```bash
# 1. metrics-server / HPA
kubectl top nodes
kubectl -n rush-coupon get hpa backend          # TARGETS 가 <unknown> 이 아니어야 함

# 2. backend 타깃이 수집되는지 (Prometheus UI: http://prometheus.<IP>.nip.io/targets 에서 rush-coupon/backend 가 UP)
kubectl -n rush-coupon get servicemonitor backend

# 2-1. DB exporter (Prometheus UI 의 Graph 에서 pg_up 이 1 이어야 함)
kubectl -n rush-coupon get pods -l app=postgres-exporter
kubectl -n rush-coupon logs deploy/postgres-exporter | tail -5

# 3. 노드/Pod 리소스 메트릭 (Prometheus UI 의 Graph 에서)
#    container_cpu_usage_seconds_total{namespace="rush-coupon"}   <- kubelet(cAdvisor)
#    kube_horizontalpodautoscaler_status_current_replicas          <- kube-state-metrics
#    node_cpu_seconds_total                                        <- node-exporter
```

## 알아둘 점

- Prometheus 스토리지가 `emptyDir`(retention 3d)이라 Prometheus Pod가 재시작되면 지표가 사라집니다. 부하 테스트 결과는 그 전에 스크린샷/내보내기로 남기세요.
- 메모리 사용률 패널/HPA는 **requests(128Mi) 대비**입니다. 이 환경의 실측 idle은 Pod당 약 44Mi(34%)라 HPA 목표 80%(약 102Mi)까지 여유가 있지만, 앱 변경으로 idle이 늘 수 있으니 `kubectl top pod -n rush-coupon`으로 가끔 확인하세요.
- HTTP 패널(RPS, 지연, 발급 결과)과 CPU 패널의 `rate()` 구간은 **`[1m]`로 고정**했습니다. 이 스택은 Grafana 데이터소스 scrape interval이 60s(`timeInterval`)라 `$__rate_interval`이 `4m`로 치환되어, 수집이 더 촘촘해도(backend 15s, cAdvisor 10s) 부하 변화가 4분 평균으로 뭉개지기 때문입니다 (Grafana 13.2.1에서 확인). 수집 주기는 차트 기본값 기준으로 cAdvisor 10s, kube-state-metrics(레플리카 패널)와 node-exporter는 전역 60s입니다. 대시보드 시간 범위를 길게(수 시간 이상) 넓혀 조회 step이 1m보다 커지면, step 사이 구간은 계산에서 빠져 짧은 스파이크가 안 보일 수 있으니 부하 테스트 분석은 짧은 시간 범위로 보세요.
- **모든 대시보드가 No data이고 Data source 드롭다운이 비어 있으면** Grafana가 Prometheus 플러그인을 못 올린 것입니다 (`.../datasources/uid/prometheus/health` 가 `Plugin not registered`).
  kube-prometheus-stack 89.x의 Grafana는 `13.2.1-distroless` 이미지에 읽기 전용 루트 파일시스템인데, Grafana 13이 시작할 때 번들 데이터소스 플러그인(prometheus, loki, tempo 등)을 최신으로 갱신하려다 `read-only file system`으로 실패하면서 플러그인이 등록에서 빠집니다.
  Helm 설치 시 `--set-string grafana.env.GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`를 주거나, 이미 설치된 경우 `kubectl -n monitoring set env deploy/kube-prometheus-stack-grafana -c grafana GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`로 해결합니다.
