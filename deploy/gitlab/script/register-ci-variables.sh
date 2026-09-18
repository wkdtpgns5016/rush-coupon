#!/usr/bin/env bash
# GitLab 프로젝트 CI/CD Variables를 API로 등록하는 스크립트.
# 값은 스크립트에 적지 않고 deploy/gitlab/.env(gitignore 대상)에서 읽는다 (설정 안 된 항목은 건너뜀).
#
# deploy/gitlab/.env.example 참고 — 필수: TOKEN, PROJECT_ID, GITLAB_HOST
# 선택: GITHUB_PAT, EXTERNAL_DB_HOST, EXTERNAL_DB_PORT, EXTERNAL_DB_NAME,
#       EXTERNAL_DB_USER, EXTERNAL_DB_PASSWORD, VITE_API_BASE_URL,
#       FRONTEND_HOST, FRONTEND_SSH_PORT, FRONTEND_SSH_KEY_PATH
#
# 사용:
#   cd deploy/gitlab && cp .env.example .env   # 아직 없다면
#   .env 채운 뒤:
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
  echo "set: $key"
  curl -s --header "PRIVATE-TOKEN: ${TOKEN}" \
    --data-urlencode "key=${key}" \
    --data-urlencode "value=${value}" \
    --data "masked=${masked}&protected=${protected}" \
    "$API" > /dev/null
}

set_var "GITHUB_PAT" "${GITHUB_PAT:-}" true
set_var "EXTERNAL_DB_HOST" "${EXTERNAL_DB_HOST:-}"
set_var "EXTERNAL_DB_PORT" "${EXTERNAL_DB_PORT:-}"
set_var "EXTERNAL_DB_NAME" "${EXTERNAL_DB_NAME:-}"
set_var "EXTERNAL_DB_USER" "${EXTERNAL_DB_USER:-}"
set_var "EXTERNAL_DB_PASSWORD" "${EXTERNAL_DB_PASSWORD:-}" true
set_var "VITE_API_BASE_URL" "${VITE_API_BASE_URL:-}"
set_var "FRONTEND_HOST" "${FRONTEND_HOST:-}"
set_var "FRONTEND_SSH_PORT" "${FRONTEND_SSH_PORT:-}"

if [ -n "${FRONTEND_SSH_KEY_PATH:-}" ]; then
  set_var "FRONTEND_SSH_PRIVATE_KEY" "$(base64 -b 0 -i "$FRONTEND_SSH_KEY_PATH")" true true
else
  echo "skip: FRONTEND_SSH_PRIVATE_KEY (FRONTEND_SSH_KEY_PATH 없음)"
fi

echo "done."
