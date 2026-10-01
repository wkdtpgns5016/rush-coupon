#!/usr/bin/env bash
# ALB Controller가 Ingress를 보고 만든 ALB는 Terraform이 모르는 리소스라서,
# 이 스크립트 없이 바로 terraform destroy를 돌리면 VPC/서브넷 삭제가 막히거나
# ALB가 고아로 남아 계속 과금될 수 있다. 그래서 순서를 강제한다:
#   1. Ingress 삭제 (ALB Controller가 ALB/타겟그룹/보안그룹을 스스로 정리하도록 트리거)
#   2. 그 VPC 안의 ALB가 실제로 사라질 때까지 폴링
#   3. terraform destroy
#
# 사용법: ./teardown.sh

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-northeast-2"

echo "== 1. Ingress 삭제 =="
if kubectl --context rush-coupon-cloud get ingress -n rush-coupon &>/dev/null; then
  kubectl --context rush-coupon-cloud delete ingress --all -n rush-coupon --ignore-not-found --wait=true
else
  echo "[SKIP] rush-coupon 네임스페이스에 Ingress가 없습니다 (이미 지워졌거나 아직 배포 전)."
fi

echo "== 2. ALB가 실제로 사라질 때까지 대기 =="
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

echo "== 3. terraform destroy =="
cd "$TF_DIR"
terraform destroy
