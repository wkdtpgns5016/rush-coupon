#!/usr/bin/env bash
# terraform/cloud-infra output과 EKS 클러스터 상태에서 나오는 값들을
# deploy/gitlab/.env에 자동으로 채워 넣는다 (register-ci-variables.sh가 쓸 입력).
#
# register-ci-variables.sh는 .env만 읽는 범용 스크립트로 남겨두고, "어디서 값을
# 가져오는지"는 이 스크립트가 따로 책임진다 — cloud-infra output이 바뀔 때마다
# (재apply, 리소스 재생성 등) 이 스크립트만 다시 돌리면 된다 (bootstrap-gitlab.sh가
# GitLab API 값을 .env에 쓰는 것과 같은 패턴, 소스만 Terraform/kubectl로 다를 뿐).
#
# 전제: terraform/cloud-infra가 이미 apply되어 있고, kubectl이 rush-coupon-cloud
# 컨텍스트로 클러스터에 접근 가능해야 한다.
#
# 사용법: ./sync-cloud-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
TF_DIR="$(cd "${SCRIPT_DIR}/../../../terraform/cloud-infra" && pwd)"
KUBE_CONTEXT="rush-coupon-cloud"

[ -f "$ENV_FILE" ] || { echo "에러: ${ENV_FILE}가 없습니다. .env.example을 복사해서 먼저 만드세요."; exit 1; }
command -v terraform >/dev/null || { echo "에러: terraform이 필요합니다"; exit 1; }
command -v kubectl >/dev/null || { echo "에러: kubectl이 필요합니다"; exit 1; }

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

echo ">>> terraform/cloud-infra output 조회..."
ECR_REPOSITORY_URL="$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url)"
FRONTEND_BUCKET="$(terraform -chdir="$TF_DIR" output -raw frontend_bucket_name)"
CLOUDFRONT_DISTRIBUTION_ID="$(terraform -chdir="$TF_DIR" output -raw frontend_cloudfront_distribution_id)"

echo ">>> backend Ingress(ALB) 주소 조회..."
BACKEND_HOST="$(kubectl --context "$KUBE_CONTEXT" get ingress backend -n rush-coupon \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
[ -n "$BACKEND_HOST" ] || { echo "에러: backend Ingress ALB 주소를 못 가져왔습니다 (아직 프로비저닝 중일 수 있음)"; exit 1; }

echo ">>> ${ENV_FILE} 갱신..."
set_env "ECR_REPOSITORY_URL" "$ECR_REPOSITORY_URL"
set_env "FRONTEND_BUCKET" "$FRONTEND_BUCKET"
set_env "CLOUDFRONT_DISTRIBUTION_ID" "$CLOUDFRONT_DISTRIBUTION_ID"
set_env "VITE_API_BASE_URL_CLOUD" "http://${BACKEND_HOST}"

echo ""
echo "=================================================================="
echo " [.env 갱신 완료]"
echo "   ECR_REPOSITORY_URL         = ${ECR_REPOSITORY_URL}"
echo "   FRONTEND_BUCKET            = ${FRONTEND_BUCKET}"
echo "   CLOUDFRONT_DISTRIBUTION_ID = ${CLOUDFRONT_DISTRIBUTION_ID}"
echo "   VITE_API_BASE_URL_CLOUD    = http://${BACKEND_HOST}"
echo ""
echo "  다음: ./register-ci-variables.sh 실행해서 GitLab CI/CD Variables에 반영"
echo "=================================================================="
