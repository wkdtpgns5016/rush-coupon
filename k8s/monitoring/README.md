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
- 메모리 사용률 패널/HPA는 **requests(128Mi) 대비**입니다. Node.js 앱은 idle 에서도 100Mi 안팎을 쓸 수 있어 HPA 가 부하 없이도 스케일 아웃할 수 있습니다. 첫 배포 후 `kubectl top pod -n rush-coupon` 으로 idle 사용량을 확인하세요.
