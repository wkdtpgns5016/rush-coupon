#!/usr/bin/env bash
# GitLab 프로젝트 CI/CD Variables를 API로 등록하는 스크립트.
# 값은 스크립트에 적지 않고 deploy/gitlab/.env(gitignore 대상)에서 읽는다 (설정 안 된 항목은 건너뜀).
#
# deploy/gitlab/.env.example 참고 — 필수: TOKEN, PROJECT_ID, GITLAB_HOST
# 선택: GITHUB_PAT, EXTERNAL_DB_HOST, EXTERNAL_DB_PORT, EXTERNAL_DB_NAME,
#       EXTERNAL_DB_USER, EXTERNAL_DB_PASSWORD, VITE_API_BASE_URL,
#       FRONTEND_HOST, FRONTEND_SSH_PORT, FRONTEND_SSH_KEY_PATH,
#       VITE_API_BASE_URL_CLOUD, FRONTEND_BUCKET, CLOUDFRONT_DISTRIBUTION_ID
#       (이 3개는 직접 채우지 않고 ./sync-cloud-env.sh가 terraform/cloud-infra output +
#        kubectl로 채운다 — 이 스크립트는 .env만 읽을 뿐 그 값의 출처는 모른다)
#
# 사용:
#   cd deploy/gitlab && cp .env.example .env   # 아직 없다면
#   .env 채운 뒤 (클라우드 값은 ./script/sync-cloud-env.sh로 자동 채우기 가능):
#   ./script/register-ci-variables.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  echo "loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${TOKEN:?TOKEN 환경변수가 필요합니다 (root Personal Access Token)}"
: "${PROJECT_ID:?PROJECT_ID 환경변수가 필요합니다}"
: "${GITLAB_HOST:?GITLAB_HOST 환경변수가 필요합니다}"

API="http://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/variables"

set_var() {
  local key="$1" value="$2" masked="${3:-false}" protected="${4:-false}"
  if [ -z "$value" ]; then
    echo "skip: $key (값 없음)"
    return
  fi
  # 있으면 PUT(갱신), 없으면 POST(생성) — POST만 쓰면 이미 존재하는 키에 400을
  # 받고도 조용히 무시돼서(응답을 버림), ALB/버킷 등 값이 바뀌어도 GitLab에는
  # 예전 값이 그대로 남는 걸 실제로 겪었다.
  if curl -s -o /dev/null -w '%{http_code}' --header "PRIVATE-TOKEN: ${TOKEN}" \
      "${API}/${key}" | grep -q '^200$'; then
    echo "update: $key"
    curl -s --request PUT --header "PRIVATE-TOKEN: ${TOKEN}" \
      --data-urlencode "value=${value}" \
      --data "masked=${masked}&protected=${protected}" \
      "${API}/${key}" > /dev/null
  else
    echo "create: $key"
    curl -s --header "PRIVATE-TOKEN: ${TOKEN}" \
      --data-urlencode "key=${key}" \
      --data-urlencode "value=${value}" \
      --data "masked=${masked}&protected=${protected}" \
      "$API" > /dev/null
  fi
}

set_var "ECR_REPOSITORY_URL" "${ECR_REPOSITORY_URL:-}"
set_var "GITHUB_PAT" "${GITHUB_PAT:-}" true
set_var "EXTERNAL_DB_HOST" "${EXTERNAL_DB_HOST:-}"
set_var "EXTERNAL_DB_PORT" "${EXTERNAL_DB_PORT:-}"
set_var "EXTERNAL_DB_NAME" "${EXTERNAL_DB_NAME:-}"
set_var "EXTERNAL_DB_USER" "${EXTERNAL_DB_USER:-}"
set_var "EXTERNAL_DB_PASSWORD" "${EXTERNAL_DB_PASSWORD:-}" true
set_var "VITE_API_BASE_URL" "${VITE_API_BASE_URL:-}"
set_var "FRONTEND_HOST" "${FRONTEND_HOST:-}"
set_var "FRONTEND_SSH_PORT" "${FRONTEND_SSH_PORT:-}"
set_var "VITE_API_BASE_URL_CLOUD" "${VITE_API_BASE_URL_CLOUD:-}"
set_var "FRONTEND_BUCKET" "${FRONTEND_BUCKET:-}"
set_var "CLOUDFRONT_DISTRIBUTION_ID" "${CLOUDFRONT_DISTRIBUTION_ID:-}"

if [ -n "${FRONTEND_SSH_KEY_PATH:-}" ]; then
  set_var "FRONTEND_SSH_PRIVATE_KEY" "$(base64 -b 0 -i "$FRONTEND_SSH_KEY_PATH")" true true
else
  echo "skip: FRONTEND_SSH_PRIVATE_KEY (FRONTEND_SSH_KEY_PATH 없음)"
fi

echo "done."
