#!/usr/bin/env bash
# 완전히 새 GitLab 인스턴스에 root PAT 부트스트랩 → 프로젝트 생성 →
# Access Token(mirror/registry-read) 발급 → imagePullSecret 생성 → Runner 등록까지
# 한 번에 처리한다. deploy/gitlab/.env(GITLAB_HOST, GITLAB_ROOT_PASSWORD)를 읽고,
# 결과(TOKEN/PROJECT_ID)를 같은 .env에 다시 써넣어서 register-ci-variables.sh가
# 이어서 쓸 수 있게 한다.
#
# 전제: deploy/gitlab이 docker compose up -d로 이미 떠서 healthy 상태.
# GitHub Secrets(GITLAB_DEPLOY_TOKEN/GITLAB_DEPLOY_USER)는 gh CLI가 없어서
# 이 스크립트가 대신 값을 출력만 하고, 등록은 직접 해야 한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${GITLAB_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${GITLAB_HOST:?deploy/gitlab/.env에 GITLAB_HOST가 필요합니다}"

GITLAB_CONTAINER="rush-coupon-gitlab"
RUNNER_CONTAINER="rush-coupon-gitlab-runner"
PROJECT_PATH="rush-coupon"
API="http://${GITLAB_HOST}/api/v4"

echo "== 0. GitLab API가 실제로 응답할 때까지 대기 =="
# 컨테이너 헬스체크(localhost 기준)는 API(Puma)가 완전히 뜨기 전에도 healthy로 뜰 수 있어서,
# API가 유효한 JSON을 반환하는지로 다시 확인한다 (버전 조회는 인증 없이도 유효한 JSON을 반환함).
until curl -s "${API}/version" | jq -e . >/dev/null 2>&1; do
  printf '.'
  sleep 3
done
echo ""

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

echo "== 1. root bootstrap Personal Access Token =="
TOKEN=$(docker exec "$GITLAB_CONTAINER" gitlab-rails runner "
puts User.find_by(username: 'root').personal_access_tokens.create!(
  name: 'bootstrap', scopes: ['api'], expires_at: 30.days.from_now
).token
" | tail -1)
echo "TOKEN 발급됨"

echo "== 2. 프로젝트 생성/조회 (${PROJECT_PATH}) =="
PROJECT_ID=$(curl -s --header "PRIVATE-TOKEN: ${TOKEN}" "${API}/projects/root%2F${PROJECT_PATH}" | jq -r '.id // empty')
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(curl -s --header "PRIVATE-TOKEN: ${TOKEN}" \
    --data "name=${PROJECT_PATH}&path=${PROJECT_PATH}&initialize_with_readme=false" \
    "${API}/projects" | jq -r '.id')
  echo "새로 생성됨: PROJECT_ID=${PROJECT_ID}"
else
  echo "이미 존재함: PROJECT_ID=${PROJECT_ID}"
fi

echo "== 3. Access Token 2개 발급 (mirror, registry-read) =="
EXPIRES="$(date -v+30d +%F 2>/dev/null || date -d '+30 days' +%F)"

MIRROR_TOKEN=$(curl -s --header "PRIVATE-TOKEN: ${TOKEN}" \
  --data "name=mirror&scopes[]=write_repository&access_level=40&expires_at=${EXPIRES}" \
  "${API}/projects/${PROJECT_ID}/access_tokens" | jq -r '.token')

REGISTRY_TOKEN=$(curl -s --header "PRIVATE-TOKEN: ${TOKEN}" \
  --data "name=registry-read&scopes[]=read_registry&access_level=20&expires_at=${EXPIRES}" \
  "${API}/projects/${PROJECT_ID}/access_tokens" | jq -r '.token')

read -r MIRROR_BOT REGISTRY_BOT <<< "$(docker exec "$GITLAB_CONTAINER" gitlab-rails runner "
mirror = PersonalAccessToken.find_by(name: 'mirror', revoked: false)
registry = PersonalAccessToken.find_by(name: 'registry-read', revoked: false)
puts \"#{mirror.user.username} #{registry.user.username}\"
" | tail -1)"
echo "mirror bot=${MIRROR_BOT}, registry-read bot=${REGISTRY_BOT}"

if [ -n "${GITLAB_BOT:-}" ] && [ "$MIRROR_BOT" != "$GITLAB_BOT" ]; then
  echo "== 3-1. mirror bot 유저네임을 GITLAB_BOT(${GITLAB_BOT})으로 변경 =="
  BOT_ID=$(curl -s --header "PRIVATE-TOKEN: ${TOKEN}" "${API}/users?username=${MIRROR_BOT}" | jq -r '.[0].id')
  curl -s --request PUT --header "PRIVATE-TOKEN: ${TOKEN}" \
    --data "username=${GITLAB_BOT}" \
    "${API}/users/${BOT_ID}" > /dev/null
  MIRROR_BOT="$GITLAB_BOT"
  echo "변경됨: mirror bot=${MIRROR_BOT}"
fi

echo "== 4. k8s namespace + imagePullSecret =="
kubectl create namespace rush-coupon --dry-run=client -o yaml | kubectl apply -f -
kubectl delete secret gitlab-registry -n rush-coupon --ignore-not-found
kubectl create secret docker-registry gitlab-registry \
  --namespace=rush-coupon \
  --docker-server="${GITLAB_HOST}:5050" \
  --docker-username="${REGISTRY_BOT}" \
  --docker-password="${REGISTRY_TOKEN}" \
  --docker-email=noreply@example.com

echo "== 5. Runner 인증 토큰 발급 + 등록 =="
RUNNER_TOKEN=$(curl -s --header "PRIVATE-TOKEN: ${TOKEN}" \
  --data "runner_type=project_type&project_id=${PROJECT_ID}&description=rush-coupon-runner" \
  "${API}/user/runners" | jq -r '.token')

docker exec "$RUNNER_CONTAINER" gitlab-runner register \
  --non-interactive \
  --url "http://${GITLAB_HOST}" \
  --token "${RUNNER_TOKEN}" \
  --executor "docker" \
  --docker-image "docker:24-cli"

echo "== 6. deploy/gitlab/.env 갱신 =="
set_env "TOKEN" "$TOKEN"
set_env "PROJECT_ID" "$PROJECT_ID"

echo ""
echo "======================================================"
echo "GitHub Secrets에 아래 값을 직접 등록하세요 (gh CLI 없어서 자동화 불가):"
echo "  GITLAB_DEPLOY_TOKEN = ${MIRROR_TOKEN}"
echo "  GITLAB_DEPLOY_USER  = ${MIRROR_BOT}"
echo "======================================================"
echo "done."
