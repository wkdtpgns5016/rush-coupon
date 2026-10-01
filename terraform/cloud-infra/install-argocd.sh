#!/usr/bin/env bash
# ArgoCD를 EKS 클러스터에 설치한다. 온프레미스의 setup-argocd.sh는 nginx-ingress에
# 강결합(ingressClassName=nginx, 워커 IP 기반 nip.io 호스트)돼있어서 그대로 못 쓰고,
# ALB용으로 새로 작성 — host를 지정하지 않고 ALB가 자동 할당하는 DNS 이름을 쓴다
# (backend/cloud-network의 Ingress와 같은 방식).
# AWS 리소스가 필요 없어서(ArgoCD는 k8s API/Git만 봄) IRSA 역할도 불필요.
#
# 사용법: ./install-argocd.sh

set -euo pipefail

KUBE_CONTEXT="rush-coupon-cloud"
NAMESPACE="argocd"
RELEASE="argocd"
CHART_VERSION="10.9.5"
REGION="ap-northeast-2"

command -v helm >/dev/null || { echo "에러: helm이 필요합니다"; exit 1; }
command -v aws >/dev/null || { echo "에러: aws CLI가 필요합니다"; exit 1; }
kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1 || {
  echo "에러: kubectl로 ${KUBE_CONTEXT} 컨텍스트에 접근할 수 없습니다"
  exit 1
}

if helm status "$RELEASE" -n "$NAMESPACE" --kube-context "$KUBE_CONTEXT" &>/dev/null; then
  echo "[SKIP] Helm 릴리스 '${RELEASE}' (ns: ${NAMESPACE})가 이미 존재합니다."
else
  echo ">>> Helm Repo 등록 및 업데이트..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  echo ">>> ArgoCD 설치 (ALB Ingress, insecure 모드 — ALB가 앞단 HTTP 처리)..."
  helm upgrade --install "$RELEASE" argo/argo-cd \
    --version "${CHART_VERSION}" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --kube-context "$KUBE_CONTEXT" \
    --set configs.params."server\.insecure"=true \
    --set server.service.type=ClusterIP \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=alb \
    --set global.domain="" \
    --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"=internet-facing \
    --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"=ip \
    --set repoServer.dnsConfig.options[0].name=ndots \
    --set-string repoServer.dnsConfig.options[0].value=1

  echo ">>> 서버 파드 기동 대기 중..."
  kubectl --context "$KUBE_CONTEXT" rollout status deployment "${RELEASE}-server" -n "$NAMESPACE" --timeout=180s
fi

echo ">>> ALB 주소 할당 대기 중..."
ARGOCD_HOST=""
for i in $(seq 1 30); do
  ARGOCD_HOST="$(kubectl --context "$KUBE_CONTEXT" get ingress "${RELEASE}-server" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$ARGOCD_HOST" ] && break
  printf '.'
  sleep 10
done
echo ""

# DNS 이름이 생겼다고 바로 접속되는 게 아니다 — ALB Controller가 AWS에 생성을
# 요청한 직후라 ALB 자체는 아직 provisioning 상태일 수 있고(2~5분 소요), 그 상태에서
# 접속하면 타임아웃/연결거부가 난다(실제로 겪음). active가 될 때까지 기다린다.
if [ -n "$ARGOCD_HOST" ]; then
  echo ">>> ALB가 실제로 active 상태가 될 때까지 대기 중..."
  for i in $(seq 1 30); do
    ALB_STATE="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?DNSName=='${ARGOCD_HOST}'].State.Code" --output text 2>/dev/null || true)"
    [ "$ALB_STATE" = "active" ] && break
    printf '.'
    sleep 10
  done
  echo ""
fi

echo ">>> 초기 admin 비밀번호 조회 중..."
ADMIN_PW=""
for i in $(seq 1 30); do
  ADMIN_PW="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$ADMIN_PW" ] && break
  sleep 2
done

echo ""
echo "=================================================================="
echo " [ArgoCD 설치 완료]"
echo ""
echo "  URL      : http://${ARGOCD_HOST:-<ALB 주소 확인 필요: kubectl get ingress argocd-server -n argocd>}"
echo "  ID       : admin"
if [ -n "$ADMIN_PW" ]; then
  echo "  Password : ${ADMIN_PW}"
  echo ""
  echo "  * 최초 로그인 후 비밀번호 변경 및 아래 시크릿 삭제 권장:"
  echo "    kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} delete secret argocd-initial-admin-secret"
else
  echo "  Password : (조회 실패) 아래 명령으로 직접 확인하세요."
  echo "    kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
fi
echo ""
echo "  CLI 로그인 (평문 HTTP + L7 프록시이므로 --plaintext --grpc-web 필요):"
echo "    argocd login ${ARGOCD_HOST:-<ALB 주소>} --plaintext --grpc-web --username admin"
echo "=================================================================="
