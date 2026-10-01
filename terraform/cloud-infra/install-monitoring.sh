#!/usr/bin/env bash
# kube-prometheus-stack(Prometheus Operator + Grafana)을 EKS 클러스터에 설치한다.
# #57/#58에서 만들어둔 ServiceMonitor(backend, postgres-exporter)가 CRD 부재로
# OutOfSync 상태인 것을 이 설치로 해소한다.
#
# 온프레미스(setup-k8s-vm/setup-monitoring.sh)와의 차이:
#   - Ingress: nginx IngressClass + nip.io 호스트 대신, ALB(host 미지정, 자동 DNS)
#     — install-argocd.sh/backend Ingress와 동일한 패턴.
#   - kubeadm 컨트롤플레인(kube-controller-manager/kube-scheduler) bind-address 패치,
#     kube-proxy metricsBindAddress 패치를 생략한다 — EKS는 관리형 컨트롤플레인이라
#     애초에 그 노드에 접근할 수 없다. 이 타겟들은 Prometheus에서 항상 DOWN으로 남는
#     게 정상이며, 이것 자체가 관리형 서비스의 특성이라 #60 비교표에 적을 내용이다.
# 그 외(retention 3d, scrape 60s, 리소스 requests/limits, 차트 버전)는 #60 비교표의
# 공정성을 위해 온프레미스와 동일하게 맞춘다.
#
# 대시보드(k8s/monitoring/)는 deploy 레포에서 별도로 적용한다 (README.md 참고):
#   kubectl apply -k k8s/monitoring --context rush-coupon-cloud
#
# 사용법: ./install-monitoring.sh

set -euo pipefail

KUBE_CONTEXT="rush-coupon-cloud"
NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"
CHART_VERSION="89.2.0"
REGION="ap-northeast-2"

command -v helm >/dev/null || { echo "에러: helm이 필요합니다"; exit 1; }
command -v aws >/dev/null || { echo "에러: aws CLI가 필요합니다"; exit 1; }
kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1 || {
  echo "에러: kubectl로 ${KUBE_CONTEXT} 컨텍스트에 접근할 수 없습니다"
  exit 1
}
kubectl --context "$KUBE_CONTEXT" get ingressclass alb >/dev/null 2>&1 || {
  echo "에러: IngressClass 'alb'가 없습니다. install-alb-controller.sh를 먼저 실행하세요."
  exit 1
}

if helm status "$RELEASE" -n "$NAMESPACE" --kube-context "$KUBE_CONTEXT" &>/dev/null; then
  echo "[SKIP] Helm 릴리스 '${RELEASE}' (ns: ${NAMESPACE})가 이미 존재합니다."
  exit 0
fi

echo ">>> Helm Repo 등록 및 업데이트..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo ">>> kube-prometheus-stack 설치 (ALB Ingress)..."
# GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false: kube-prometheus-stack 89.x의 Grafana
# 13.2.1-distroless 이미지는 읽기 전용 루트 파일시스템인데, 기동 시 번들 플러그인을
# 최신으로 갱신하려다 read-only file system으로 실패해 플러그인이 아예 등록에서
# 빠지는 문제가 있다 (온프레미스에서 실제로 겪음 — k8s/monitoring/README.md 참고).
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --kube-context "$KUBE_CONTEXT" \
  --set-string grafana.env.GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false \
  --set alertmanager.enabled=false \
  --set kubeEtcd.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=3d \
  --set prometheus.prometheusSpec.scrapeInterval=60s \
  --set prometheus.prometheusSpec.evaluationInterval=60s \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=350Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set prometheusOperator.resources.requests.memory=64Mi \
  --set prometheusOperator.resources.limits.memory=200Mi \
  --set grafana.persistence.enabled=false \
  --set grafana.resources.requests.memory=192Mi \
  --set grafana.resources.limits.memory=768Mi \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=alb \
  --set grafana.ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"=internet-facing \
  --set grafana.ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"=ip \
  --set grafana.ingress.path=/ \
  --set grafana.ingress.pathType=Prefix \
  --set prometheus.ingress.enabled=true \
  --set prometheus.ingress.ingressClassName=alb \
  --set prometheus.ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"=internet-facing \
  --set prometheus.ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"=ip \
  --set prometheus.ingress.paths[0]=/ \
  --set prometheus.ingress.pathType=Prefix \
  --set prometheus-node-exporter.resources.requests.memory=32Mi \
  --set prometheus-node-exporter.resources.limits.memory=64Mi \
  --set kube-state-metrics.resources.requests.memory=64Mi \
  --set kube-state-metrics.resources.limits.memory=200Mi

echo ">>> 컨트롤러/Grafana 기동 대기 중..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment "${RELEASE}-operator" -n "$NAMESPACE" --timeout=180s
kubectl --context "$KUBE_CONTEXT" rollout status deployment "${RELEASE}-grafana" -n "$NAMESPACE" --timeout=180s

echo ">>> Prometheus StatefulSet 생성 대기..."
for _ in $(seq 1 30); do
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get statefulset "prometheus-${RELEASE}-prometheus" &>/dev/null && break
  sleep 2
done
kubectl --context "$KUBE_CONTEXT" rollout status statefulset "prometheus-${RELEASE}-prometheus" -n "$NAMESPACE" --timeout=300s

echo ">>> ALB 주소 할당 대기 중..."
GRAFANA_HOST=""
for i in $(seq 1 30); do
  GRAFANA_HOST="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get ingress "${RELEASE}-grafana" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$GRAFANA_HOST" ] && break
  printf '.'
  sleep 10
done
echo ""

# install-argocd.sh와 같은 이유 — DNS 이름이 나와도 AWS 쪽 ALB가 아직 provisioning
# 상태일 수 있어 바로 접속하면 실패한다. active가 될 때까지 기다린다.
if [ -n "$GRAFANA_HOST" ]; then
  echo ">>> ALB가 실제로 active 상태가 될 때까지 대기 중..."
  for i in $(seq 1 30); do
    ALB_STATE="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?DNSName=='${GRAFANA_HOST}'].State.Code" --output text 2>/dev/null || true)"
    [ "$ALB_STATE" = "active" ] && break
    printf '.'
    sleep 10
  done
  echo ""
fi

GRAFANA_PW="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get secret "${RELEASE}-grafana" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"

echo ""
echo "=================================================================="
echo " [모니터링 스택 설치 완료]"
echo ""
echo "  Grafana  : http://${GRAFANA_HOST:-<ALB 주소 확인 필요: kubectl -n monitoring get ingress ${RELEASE}-grafana>}"
echo "    ID/PW  : admin / ${GRAFANA_PW:-(secret 확인 필요)}"
echo ""
echo "  프로파일 : retention 3d / scrape 60s / Alertmanager 비활성 / 스토리지 emptyDir (온프레미스와 동일)"
echo ""
echo "  다음 단계:"
echo "    1. 대시보드 적용 (deploy 레포에서): kubectl apply -k k8s/monitoring --context ${KUBE_CONTEXT}"
echo "    2. ServiceMonitor Synced 확인: kubectl --context ${KUBE_CONTEXT} -n rush-coupon get servicemonitor"
echo "    3. HPA 메트릭 확인: kubectl --context ${KUBE_CONTEXT} -n rush-coupon get hpa backend"
echo "=================================================================="
