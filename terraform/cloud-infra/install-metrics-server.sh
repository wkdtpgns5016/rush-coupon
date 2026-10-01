#!/usr/bin/env bash
# metrics-server를 EKS 클러스터에 설치한다 (backend HPA가 CPU/메모리 메트릭을 받으려면 필요).
# 온프레미스(setup-k8s-vm/setup-metrics-server.sh)는 kubeadm 자체서명 kubelet 인증서 때문에
# --kubelet-insecure-tls가 필요했는데, EKS는 kubelet 서빙 인증서가 정상 서명돼 있어서
# 그 플래그 없이 표준 설치로 시도한다.
#
# 사용법: ./install-metrics-server.sh

set -euo pipefail

KUBE_CONTEXT="rush-coupon-cloud"
NAMESPACE="kube-system"
RELEASE="metrics-server"
CHART_VERSION="3.14.0"

command -v helm >/dev/null || { echo "에러: helm이 필요합니다"; exit 1; }
kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1 || {
  echo "에러: kubectl로 ${KUBE_CONTEXT} 컨텍스트에 접근할 수 없습니다"
  exit 1
}

if helm status "$RELEASE" -n "$NAMESPACE" --kube-context "$KUBE_CONTEXT" &>/dev/null; then
  echo "[SKIP] Helm 릴리스 '${RELEASE}' (ns: ${NAMESPACE})가 이미 존재합니다."
  exit 0
fi

echo ">>> Helm Repo 등록 및 업데이트..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

echo ">>> metrics-server 설치..."
helm upgrade --install "$RELEASE" metrics-server/metrics-server \
  --version "${CHART_VERSION}" \
  --namespace "$NAMESPACE" \
  --kube-context "$KUBE_CONTEXT"

echo ">>> 파드 기동 대기 중..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment "$RELEASE" -n "$NAMESPACE" --timeout=120s

echo ""
echo "=================================================================="
echo " [metrics-server 설치 완료]"
echo ""
echo "  확인:"
echo "    kubectl --context ${KUBE_CONTEXT} top nodes"
echo "    kubectl --context ${KUBE_CONTEXT} -n rush-coupon get hpa backend"
echo ""
echo "  * TLS 인증서 에러(x509)로 Pod가 안 뜨면 EKS 노드 kubelet 서빙 인증서 문제이니,"
echo "    아래로 --kubelet-insecure-tls를 추가해 재설치:"
echo "    helm upgrade --install ${RELEASE} metrics-server/metrics-server \\"
echo "      --version ${CHART_VERSION} --namespace ${NAMESPACE} --kube-context ${KUBE_CONTEXT} \\"
echo "      --set args=\"{--kubelet-insecure-tls}\""
echo "=================================================================="
