#!/usr/bin/env bash
# GitLab(+Runner) docker compose를 올리고, 원하면 이어서 부트스트랩 스크립트
# (프로젝트 생성/Access Token/imagePullSecret/Runner 등록)까지 자동 실행한다.
#
# 사용:
#   ./up.sh                 # 대화형으로 물어봄
#   ./up.sh --bootstrap     # 묻지 않고 부트스트랩까지 실행
#   ./up.sh --no-bootstrap  # 묻지 않고 compose up만 실행

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-}"

echo "== docker compose up -d =="
docker compose up -d

run_bootstrap() {
  echo "== GitLab이 healthy 상태가 될 때까지 대기 =="
  until [ "$(docker inspect -f '{{.State.Health.Status}}' rush-coupon-gitlab 2>/dev/null)" = "healthy" ]; do
    printf '.'
    sleep 5
  done
  echo ""
  echo "== 부트스트랩 스크립트 실행 =="
  ./script/bootstrap-gitlab.sh
}

case "$MODE" in
  --bootstrap)
    run_bootstrap
    ;;
  --no-bootstrap)
    echo "compose up만 실행했습니다. 부트스트랩은 나중에 ./script/bootstrap-gitlab.sh로 직접 실행하세요."
    ;;
  "")
    read -r -p "GitLab이 healthy 되면 이어서 부트스트랩 스크립트(프로젝트/토큰/러너 등록)까지 자동 실행할까요? [y/N] " ans
    case "$ans" in
      [yY]*) run_bootstrap ;;
      *) echo "compose up만 실행했습니다. 부트스트랩은 나중에 ./script/bootstrap-gitlab.sh로 직접 실행하세요." ;;
    esac
    ;;
  *)
    echo "사용법: $0 [--bootstrap|--no-bootstrap]" >&2
    exit 1
    ;;
esac
