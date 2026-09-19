# k8s/monitoring

rush-coupon **애플리케이션 쪽** 모니터링 리소스입니다. Prometheus/Grafana 자체(kube-prometheus-stack)와 metrics-server는
[setup-k8s-vm](https://github.com/wkdtpgns5016/setup-k8s-vm)의 `install-addons.sh`가 설치합니다.

| 무엇 | 어디 | 적용 방식 |
|---|---|---|
| backend `/metrics` 수집 (ServiceMonitor, 15s) | `k8s/backend/base/servicemonitor.yaml` | ArgoCD `backend` Application이 자동 적용 |
| backend HPA (2~10, CPU 70% / 메모리 80%) | `k8s/backend/base/hpa.yaml` | ArgoCD가 자동 적용 |
| Grafana 대시보드 "Rush Coupon API" | `k8s/monitoring/dashboards/rush-coupon-api.json` | 아래 `kubectl apply -k` (ArgoCD 추적 대상 아님) |

## 대시보드 적용

```bash
kubectl apply -k k8s/monitoring
```

Grafana 사이드카가 잠시 뒤 자동으로 읽습니다. 대시보드는 프로비저닝이라 UI에서 수정해도 저장되지 않으니, 고칠 때는 JSON을 수정한 뒤 다시 apply 합니다.

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

# 3. 노드/Pod 리소스 메트릭 (Prometheus UI 의 Graph 에서)
#    container_cpu_usage_seconds_total{namespace="rush-coupon"}   <- kubelet(cAdvisor)
#    kube_horizontalpodautoscaler_status_current_replicas          <- kube-state-metrics
#    node_cpu_seconds_total                                        <- node-exporter
```

## 알아둘 점

- Prometheus 스토리지가 `emptyDir`(retention 3d)이라 Prometheus Pod가 재시작되면 지표가 사라집니다. 부하 테스트 결과는 그 전에 스크린샷/내보내기로 남기세요.
- 메모리 사용률 패널/HPA는 **requests(128Mi) 대비**입니다. 이 환경의 실측 idle은 Pod당 약 44Mi(34%)라 HPA 목표 80%(약 102Mi)까지 여유가 있지만, 앱 변경으로 idle이 늘 수 있으니 `kubectl top pod -n rush-coupon`으로 가끔 확인하세요.
- HTTP 패널(RPS, 지연, 발급 결과)의 `rate()` 구간은 **`[1m]`로 고정**했습니다. 이 스택은 Grafana 데이터소스 scrape interval이 60s(`timeInterval`)라 `$__rate_interval`이 `4m`로 치환되어, backend를 15s로 수집해도 부하 변화가 4분 평균으로 뭉개지기 때문입니다 (Grafana 13.2.1에서 확인). CPU·메모리(cAdvisor, 60s 수집)는 `$__rate_interval`을 그대로 씁니다. 대시보드 시간 범위를 길게(수 시간 이상) 넓혀 조회 step이 1m보다 커지면, step 사이 구간은 계산에서 빠져 짧은 스파이크가 안 보일 수 있으니 부하 테스트 분석은 짧은 시간 범위로 보세요.
- **모든 대시보드가 No data이고 Data source 드롭다운이 비어 있으면** Grafana가 Prometheus 플러그인을 못 올린 것입니다 (`.../datasources/uid/prometheus/health` 가 `Plugin not registered`).
  kube-prometheus-stack 89.x의 Grafana는 `13.2.1-distroless` 이미지에 읽기 전용 루트 파일시스템인데, Grafana 13이 시작할 때 번들 데이터소스 플러그인(prometheus, loki, tempo 등)을 최신으로 갱신하려다 `read-only file system`으로 실패하면서 플러그인이 등록에서 빠집니다.
  Helm 설치 시 `--set-string grafana.env.GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`를 주거나, 이미 설치된 경우 `kubectl -n monitoring set env deploy/kube-prometheus-stack-grafana -c grafana GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`로 해결합니다.
