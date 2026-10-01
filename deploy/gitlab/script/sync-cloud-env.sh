#!/usr/bin/env bash
# terraform/cloud-infra output에서 나오는 값들을 deploy/gitlab/.env에 자동으로
# 채워 넣는다 (register-ci-variables.sh가 쓸 입력).
#
# register-ci-variables.sh는 .env만 읽는 범용 스크립트로 남겨두고, "어디서 값을
# 가져오는지"는 이 스크립트가 따로 책임진다 — cloud-infra output이 바뀔 때마다
# (재apply, 리소스 재생성 등) 이 스크립트만 다시 돌리면 된다 (bootstrap-gitlab.sh가
# GitLab API 값을 .env에 쓰는 것과 같은 패턴, 소스만 Terraform인 것만 다르다).
#
# 전제: terraform/cloud-infra가 이미 apply되어 있고(install-all.sh까지 끝난 상태,
# enable_backend_cdn=true 포함), 그 state를 로컬에서 읽을 수 있어야 한다.
#
# 사용법: ./sync-cloud-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
TF_DIR="$(cd "${SCRIPT_DIR}/../../../terraform/cloud-infra" && pwd)"

[ -f "$ENV_FILE" ] || { echo "에러: ${ENV_FILE}가 없습니다. .env.example을 복사해서 먼저 만드세요."; exit 1; }
command -v terraform >/dev/null || { echo "에러: terraform이 필요합니다"; exit 1; }

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
# backend ALB(http)를 그대로 쓰면 프론트(CloudFront, https)에서 Mixed Content로
# 브라우저가 막는다 — install-all.sh가 만드는 backend용 CloudFront(https) 주소를 쓴다.
BACKEND_CDN_URL="$(terraform -chdir="$TF_DIR" output -raw backend_cdn_url)"
[ -n "$BACKEND_CDN_URL" ] && [ "$BACKEND_CDN_URL" != "null" ] || {
  echo "에러: backend_cdn_url이 비어 있습니다. install-all.sh(특히 enable_backend_cdn 활성화 단계)가 끝났는지 확인하세요."
  exit 1
}

echo ">>> ${ENV_FILE} 갱신..."
set_env "ECR_REPOSITORY_URL" "$ECR_REPOSITORY_URL"
set_env "FRONTEND_BUCKET" "$FRONTEND_BUCKET"
set_env "CLOUDFRONT_DISTRIBUTION_ID" "$CLOUDFRONT_DISTRIBUTION_ID"
set_env "VITE_API_BASE_URL_CLOUD" "$BACKEND_CDN_URL"

echo ""
echo "=================================================================="
echo " [.env 갱신 완료]"
echo "   ECR_REPOSITORY_URL         = ${ECR_REPOSITORY_URL}"
echo "   FRONTEND_BUCKET            = ${FRONTEND_BUCKET}"
echo "   CLOUDFRONT_DISTRIBUTION_ID = ${CLOUDFRONT_DISTRIBUTION_ID}"
echo "   VITE_API_BASE_URL_CLOUD    = ${BACKEND_CDN_URL}"
echo ""
echo "  다음: ./register-ci-variables.sh 실행해서 GitLab CI/CD Variables에 반영"
echo "=================================================================="
