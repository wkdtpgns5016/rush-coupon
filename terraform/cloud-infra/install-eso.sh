#!/usr/bin/env bash
# External Secrets Operator를 EKS 클러스터에 설치한다.
# Terraform(eso.tf)이 준비해둔 IRSA 역할을 ServiceAccount에 annotation으로 연결한다.
# install-alb-controller.sh와 동일한 패턴 — 이미 설치돼 있으면 건너뛴다.
#
# 사용법: ./install-eso.sh

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT="rush-coupon-cloud"
NAMESPACE="external-secrets"
RELEASE="external-secrets"
CHART_VERSION="2.11.0"

command -v helm >/dev/null || { echo "에러: helm이 필요합니다"; exit 1; }
kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1 || {
  echo "에러: kubectl로 ${KUBE_CONTEXT} 컨텍스트에 접근할 수 없습니다"
  exit 1
}

if helm status "$RELEASE" -n "$NAMESPACE" --kube-context "$KUBE_CONTEXT" &>/dev/null; then
  echo "[SKIP] Helm 릴리스 '${RELEASE}' (ns: ${NAMESPACE})가 이미 존재합니다."
  exit 0
fi

ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw eso_role_arn)"
echo ">>> IRSA 역할: ${ROLE_ARN}"

echo ">>> Helm Repo 등록 및 업데이트..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

echo ">>> External Secrets Operator 설치..."
helm upgrade --install "$RELEASE" external-secrets/external-secrets \
  --version "${CHART_VERSION}" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --kube-context "$KUBE_CONTEXT" \
  --set serviceAccount.name=external-secrets \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"

echo ">>> 컨트롤러 파드 기동 대기 중..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment "$RELEASE" -n "$NAMESPACE" --timeout=120s

echo ""
echo "=================================================================="
echo " [External Secrets Operator 설치 완료]"
kubectl --context "$KUBE_CONTEXT" get pods -n "$NAMESPACE"
echo "=================================================================="
