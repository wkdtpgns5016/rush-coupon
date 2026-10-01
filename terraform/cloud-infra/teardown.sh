#!/usr/bin/env bash
# ALB Controller가 Ingress를 보고 만든 ALB는 Terraform이 모르는 리소스라서,
# 이 스크립트 없이 바로 terraform destroy를 돌리면 VPC/서브넷 삭제가 막히거나
# ALB가 고아로 남아 계속 과금될 수 있다. 그래서 순서를 강제한다:
#   1. ArgoCD Application 삭제 (selfHeal이 Ingress를 도로 살려내는 걸 먼저 차단)
#   2. Ingress 삭제 (ALB Controller가 ALB/타겟그룹/보안그룹을 스스로 정리하도록 트리거)
#   3. 그 VPC 안의 ALB가 실제로 사라질 때까지 폴링
#   4. terraform destroy
#
# 사용법: ./teardown.sh

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-northeast-2"

echo "== 1. ArgoCD Application 삭제 =="
# syncPolicy.automated.selfHeal=true라서, Ingress를 먼저 지우면 ArgoCD가 git과
# 다르다고 판단해 수 초 안에 똑같은 Ingress를 재생성하고 ALB Controller가 새 ALB를
# 또 만든다(실제로 재현 확인 — 2단계의 삭제-대기 루프가 영원히 안 끝나게 됨). 이
# Application엔 cascade 삭제 finalizer가 없어서, 지워도 하위 리소스(Deployment 등)는
# 안 건드리고 ArgoCD가 더 이상 감시만 멈춘다 — 그 상태에서 2단계가 안전해진다.
if kubectl --context rush-coupon-cloud get application backend -n argocd &>/dev/null; then
  kubectl --context rush-coupon-cloud delete application backend -n argocd --wait=true
else
  echo "[SKIP] ArgoCD Application 'backend'가 없습니다."
fi

echo "== 2. Ingress 삭제 (전체 네임스페이스) =="
# rush-coupon(backend)뿐 아니라 argocd(argocd-server), monitoring(grafana/prometheus)에도
# 각자 ALB를 만드는 Ingress가 있다 — 네임스페이스 하나만 지우면 나머지 ALB가 고아로 남는다
# (#58/#66에서 ArgoCD/모니터링을 추가하면서 실제로 겪음).
if kubectl --context rush-coupon-cloud get ingress -A --no-headers 2>/dev/null | grep -q .; then
  kubectl --context rush-coupon-cloud delete ingress --all -A --ignore-not-found --wait=true
else
  echo "[SKIP] Ingress가 없습니다 (이미 지워졌거나 아직 배포 전)."
fi

echo "== 3. ALB가 실제로 사라질 때까지 대기 =="
VPC_ID="$(terraform -chdir="$TF_DIR" output -raw vpc_id 2>/dev/null || true)"

if [ -z "$VPC_ID" ]; then
  echo "[SKIP] vpc_id를 못 가져왔습니다 (이미 destroy된 상태일 수 있음)."
else
  COUNT=0
  for i in $(seq 1 30); do
    COUNT="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" --output text 2>/dev/null || echo 0)"
    [ "$COUNT" = "0" ] && break
    echo "ALB가 아직 ${COUNT}개 남아있음, 대기 중... (${i}/30)"
    sleep 10
  done

  if [ "$COUNT" != "0" ]; then
    echo "" >&2
    echo "타임아웃: ALB가 30회 폴링 후에도 안 지워졌습니다. 수동 확인 필요:" >&2
    echo "  aws elbv2 describe-load-balancers --region ${REGION} --query \"LoadBalancers[?VpcId=='${VPC_ID}']\"" >&2
    exit 1
  fi

  echo "ALB 정리 확인됨 — ENI 디태치 여유를 두고 15초 대기"
  sleep 15
fi

echo "== 4. terraform destroy =="
cd "$TF_DIR"
terraform destroy

# backend-cdn.tf는 enable_backend_cdn=true일 때 kubernetes_ingress_v1로 backend
# Ingress를 조회한다 — 이 플래그가 true인 채로 남아있으면, 클러스터 자체가 사라진
# 다음번 첫 terraform apply가 그 Ingress를 못 찾아서 바로 에러난다. install-all.sh가
# 다음에 또 처음부터(false) 켤 수 있게 여기서 지운다.
rm -f "${TF_DIR}/backend-cdn.auto.tfvars"
