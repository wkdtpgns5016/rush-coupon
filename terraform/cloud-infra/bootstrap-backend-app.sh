#!/usr/bin/env bash
# install-all.sh가 끝난 뒤, 별도 레포(deploy 브랜치)에 있는 모니터링 대시보드와
# ArgoCD Application을 적용해서 backend/worker를 실제로 배포한다.
#
# 로컬에 이미 떠 있는 워크트리(rush-coupon-deploy 등) 경로를 가정하지 않는다 — 어느
# 머신에서 실행해도 같게 동작하도록, backend-deploy-cloud CI job과 같은 방식으로
# deploy 브랜치를 임시 디렉터리에 새로 clone해서 쓰고 끝나면 지운다.
#
# 사용법: ./bootstrap-backend-app.sh

set -euo pipefail

KUBE_CONTEXT="rush-coupon-cloud"
REPO_URL="https://github.com/wkdtpgns5016/rush-coupon.git"

command -v git >/dev/null || { echo "에러: git이 필요합니다"; exit 1; }
kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1 || {
  echo "에러: kubectl로 ${KUBE_CONTEXT} 컨텍스트에 접근할 수 없습니다"
  exit 1
}
kubectl --context "$KUBE_CONTEXT" get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 || {
  echo "에러: ServiceMonitor CRD가 없습니다. install-all.sh(특히 install-monitoring.sh)를 먼저 실행하세요."
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo ">>> deploy 브랜치 임시 clone..."
git clone --branch deploy --single-branch --depth 1 "$REPO_URL" "$TMP_DIR" >/dev/null

echo ">>> Grafana 대시보드 적용..."
kubectl apply -k "${TMP_DIR}/k8s/monitoring" --context "$KUBE_CONTEXT"

echo ">>> ArgoCD Application(backend) 적용..."
kubectl apply -f "${TMP_DIR}/k8s/backend/argocd-application-cloud.yaml" --context "$KUBE_CONTEXT"

echo ">>> ArgoCD 동기화 대기 중..."
for i in $(seq 1 30); do
  STATUS="$(kubectl --context "$KUBE_CONTEXT" get application backend -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [ "$STATUS" = "Synced" ] && break
  printf '.'
  sleep 10
done
echo ""

echo ""
echo "=================================================================="
echo " [backend 앱 배포 완료]"
kubectl --context "$KUBE_CONTEXT" get application backend -n argocd
echo ""
kubectl --context "$KUBE_CONTEXT" get pods -n rush-coupon
echo ""
echo "  * image.env가 가리키는 이미지가 ECR에 없으면(처음 구성 시) 파드가"
echo "    ImagePullBackOff로 남는 게 정상입니다 — backend-build/backend-deploy-cloud"
echo "    파이프라인이 한 번 돈 뒤에 정상화됩니다."
echo "=================================================================="
