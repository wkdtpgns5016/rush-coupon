#!/usr/bin/env bash
# terraform apply 이후 실행한다. 사용법: terraform apply && ./bootstrap-and-verify.sh
#
# Tailscale에 새 GitLab+Runner 인스턴스가 나타날 때까지 기다렸다가, 기존
# deploy/gitlab/{up.sh,script/bootstrap-gitlab.sh,script/sync-cloud-env.sh,
# script/register-ci-variables.sh}를 그대로 재사용해 GitLab 배포 → 부트스트랩 →
# cloud-infra 값 반영 → CI 변수 등록 → GitHub Secrets/Variables 갱신까지 끝낸다.
#
# 핵심 트릭: DOCKER_HOST=ssh://ubuntu@<tailscale-ip> 로 docker 명령만 원격 조준한다.
# 스크립트 자체(kubectl, curl, .env 읽기)는 계속 이 Mac에서 실행되므로 kubeconfig,
# GITHUB_PAT, DB 비밀번호, 프론트엔드 SSH 프라이빗 키 등은 EC2로 전혀 넘어가지 않는다.

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITLAB_DIR="$(cd "${TF_DIR}/../../deploy/gitlab" && pwd)"
ENV_FILE="${GITLAB_DIR}/.env"

command -v tailscale >/dev/null || { echo "tailscale CLI를 찾을 수 없습니다" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq가 필요합니다 (brew install jq)" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI가 필요합니다" >&2; exit 1; }
[ -f "$ENV_FILE" ] || {
  echo "${ENV_FILE}이 없습니다. 먼저 다음을 실행해 채워주세요:" >&2
  echo "  cd ${GITLAB_DIR} && cp .env.example .env" >&2
  exit 1
}

HOSTNAME_TAG="$(terraform -chdir="$TF_DIR" output -raw tailscale_hostname)"

echo "== 1. Tailscale에 '${HOSTNAME_TAG}'가 Online으로 뜰 때까지 대기 =="
IP=""
for _ in $(seq 1 60); do
  IP="$(tailscale status --json \
    | jq -r --arg h "$HOSTNAME_TAG" \
      '.Peer[] | select(.HostName == $h and .Online == true) | .TailscaleIPs[0]' \
    2>/dev/null | head -1)"
  [ -n "$IP" ] && [ "$IP" != "null" ] && break
  printf '.'
  sleep 5
done
echo ""
if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  INSTANCE_ID="$(terraform -chdir="$TF_DIR" output -raw instance_id 2>/dev/null || echo "?")"
  echo "타임아웃: tailnet에 '${HOSTNAME_TAG}'가 나타나지 않았습니다." >&2
  echo "부팅 로그 확인: aws ec2 get-console-output --instance-id ${INSTANCE_ID} --profile rush-coupon-admin" >&2
  exit 1
fi
echo "인스턴스 Tailscale IP: ${IP}"

echo "== 2. deploy/gitlab/.env 의 GITLAB_HOST/GITLAB_EXTERNAL_URL 갱신 =="
sed -i.bak \
  -e "s|^GITLAB_HOST=.*|GITLAB_HOST=${IP}|" \
  -e "s|^GITLAB_EXTERNAL_URL=.*|GITLAB_EXTERNAL_URL=http://${IP}|" \
  "$ENV_FILE"
rm -f "${ENV_FILE}.bak"

echo "== 3. SSH 접속 가능해질 때까지 대기 =="
until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@${IP}" true 2>/dev/null; do
  printf '.'
  sleep 5
done
echo ""

echo "== 4. docker compose up + bootstrap (원격 docker 데몬, kubectl/curl은 로컬 실행) =="
export DOCKER_HOST="ssh://ubuntu@${IP}"
(cd "$GITLAB_DIR" && ./up.sh --bootstrap)

echo "== 4-1. terraform/cloud-infra output + kubectl → .env 자동 반영 =="
# #59: ECR_REPOSITORY_URL/FRONTEND_BUCKET/CLOUDFRONT_DISTRIBUTION_ID/VITE_API_BASE_URL_CLOUD를
# 직접 채우는 대신 여기서 가져온다. cloud-infra가 아직 apply 안 됐거나 backend Ingress가
# 아직 없으면 이 스텝에서 에러로 멈춘다 — cloud-infra apply를 먼저 끝내고 다시 실행하면 된다.
(cd "$GITLAB_DIR" && ./script/sync-cloud-env.sh)

echo "== 5. CI/CD Variables 등록 (GitLab 프로젝트) =="
(cd "$GITLAB_DIR" && ./script/register-ci-variables.sh)

echo "== 6. GitHub Actions Variables/Secrets 갱신 =="
# bootstrap-gitlab.sh가 4단계에서 .env에 MIRROR_TOKEN/MIRROR_BOT을 이미 저장해둠
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${MIRROR_TOKEN:?bootstrap-gitlab.sh가 MIRROR_TOKEN을 .env에 못 남겼습니다}"
: "${MIRROR_BOT:?bootstrap-gitlab.sh가 MIRROR_BOT을 .env에 못 남겼습니다}"

gh variable set GITLAB_HOST --body "${IP}"
gh secret set GITLAB_DEPLOY_USER --body "${MIRROR_BOT}"
gh secret set GITLAB_DEPLOY_TOKEN --body "${MIRROR_TOKEN}"
echo "GITLAB_HOST(변수)=${IP}, GITLAB_DEPLOY_USER/GITLAB_DEPLOY_TOKEN(시크릿) 갱신 완료"
# GITLAB_PROJECT_PATH는 GitLab 프로젝트 경로가 매번 root/rush-coupon으로 고정이라 안 건드림
# TS_AUTHKEY는 GitHub Actions 러너용 별개 키라 안 건드림

echo "== 7. 스모크 테스트: userland-proxy 활성화 확인 (헤어핀 이슈 우회 확인) =="
ssh "ubuntu@${IP}" "docker info | grep -i userland"

cat <<EOF

======================================================
완료. 남은 수동 작업은 하나뿐입니다:
  커밋을 하나 push해서 backend-build → backend-deploy 파이프라인이
  실제로 도는지 확인하세요.
======================================================
EOF
