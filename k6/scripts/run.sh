#!/usr/bin/env bash
# k6 시나리오를 실행하고, 끝나면 테스트 전용 쿠폰([k6-* 접두사])을 cleanup.sql로 자동 정리한다.
# k6 JS 런타임은 Postgres에 직접 붙을 수 없어서(순정 k6엔 SQL 확장이 없음), psql을 별도로 호출한다.
#
# 사용법: scripts/run.sh <baseline|spike> [k6 run에 넘길 추가 인자...]
# 예:     scripts/run.sh spike -e SPIKE_VUS=3000
set -uo pipefail

SCENARIO="${1:?사용법: scripts/run.sh <baseline|spike> [k6 run 인자...]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_DIR="$(dirname "$SCRIPT_DIR")"

: "${DB_HOST:?cleanup을 위해 DB_HOST가 필요합니다 (.env 참고)}"
: "${DB_USERNAME:?cleanup을 위해 DB_USERNAME이 필요합니다 (.env 참고)}"
: "${DB_PASSWORD:?cleanup을 위해 DB_PASSWORD가 필요합니다 (.env 참고)}"
: "${DB_DATABASE:?cleanup을 위해 DB_DATABASE가 필요합니다 (.env 참고)}"

k6 run "$K6_DIR/scenarios/${SCENARIO}.js" "$@"
K6_EXIT=$?

echo "테스트 데이터 정리 중 (title LIKE '[k6-%')..."
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USERNAME" -d "$DB_DATABASE" \
  -f "$SCRIPT_DIR/cleanup.sql"

exit "$K6_EXIT"
