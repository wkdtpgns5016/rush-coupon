#!/usr/bin/env bash
# AWS Load Balancer Controller를 EKS 클러스터에 설치한다.
# Terraform(alb-controller.tf)이 준비해둔 IRSA 역할을 ServiceAccount에 annotation으로 연결한다.
# 이미 설치돼 있으면(Helm 릴리스 존재) 건너뛴다 — 기존 install-addons.sh 패턴과 동일.
#
# 사용법: ./install-alb-controller.sh

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT="rush-coupon-cloud"
NAMESPACE="kube-system"
RELEASE="aws-load-balancer-controller"
CHART_VERSION="3.5.0"

command -v helm >/dev/null || { echo "에러: helm이 필요합니다"; exit 1; }
kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1 || {
  echo "에러: kubectl로 ${KUBE_CONTEXT} 컨텍스트에 접근할 수 없습니다"
  exit 1
}

if helm status "$RELEASE" -n "$NAMESPACE" --kube-context "$KUBE_CONTEXT" &>/dev/null; then
  echo "[SKIP] Helm 릴리스 '${RELEASE}' (ns: ${NAMESPACE})가 이미 존재합니다."
  exit 0
fi

CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)"
VPC_ID="$(terraform -chdir="$TF_DIR" output -raw vpc_id)"
ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw alb_controller_role_arn)"
REGION="ap-northeast-2"

echo ">>> 클러스터: ${CLUSTER_NAME} / VPC: ${VPC_ID} / IRSA 역할: ${ROLE_ARN}"

echo ">>> Helm Repo 등록 및 업데이트..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo ">>> AWS Load Balancer Controller 설치..."
helm upgrade --install "$RELEASE" eks/aws-load-balancer-controller \
  --version "${CHART_VERSION}" \
  --namespace "$NAMESPACE" \
  --kube-context "$KUBE_CONTEXT" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"

echo ">>> 컨트롤러 파드 기동 대기 중..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment "$RELEASE" -n "$NAMESPACE" --timeout=120s

echo ""
echo "=================================================================="
echo " [AWS Load Balancer Controller 설치 완료]"
kubectl --context "$KUBE_CONTEXT" get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=aws-load-balancer-controller"
echo "=================================================================="
