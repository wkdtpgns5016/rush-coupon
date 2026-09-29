#!/usr/bin/env bash
# k6 시나리오를 실행하고, (#47) Worker 배출이 끝나길 기다려 latency-report.sql로 종단 지연을
# 계산한 뒤, 테스트 전용 쿠폰([k6-* 접두사])을 cleanup.sql로 자동 정리한다.
# k6 JS 런타임은 Postgres에 직접 붙을 수 없어서(순정 k6엔 SQL 확장이 없음), psql을 별도로 호출한다.
#
# 사용법: scripts/run.sh <baseline|spike|scaleout> [k6 run에 넘길 추가 인자...]
# 예:     scripts/run.sh spike -e SPIKE_VUS=3000
set -uo pipefail

SCENARIO="${1:?사용법: scripts/run.sh <baseline|spike|scaleout> [k6 run 인자...]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_DIR="$(dirname "$SCRIPT_DIR")"

: "${DB_HOST:?cleanup을 위해 DB_HOST가 필요합니다 (.env 참고)}"
: "${DB_USERNAME:?cleanup을 위해 DB_USERNAME이 필요합니다 (.env 참고)}"
: "${DB_PASSWORD:?cleanup을 위해 DB_PASSWORD가 필요합니다 (.env 참고)}"
: "${DB_DATABASE:?cleanup을 위해 DB_DATABASE가 필요합니다 (.env 참고)}"

k6 run "$K6_DIR/scenarios/${SCENARIO}.js" "$@"
K6_EXIT=$?

# (#47) k6가 끝나도 RabbitMQ 큐에 아직 남은 메시지를 Worker가 계속 consume해 저장한다.
# 종단 지연(requested_at~issued_at)을 latency-report.sql로 계산하려면 그 배출이 끝난 뒤여야
# 하는데, DELETE처럼 "실패하면 아직 안 끝났다"는 신호를 못 쓰는 단순 SELECT라 대신
# coupon_issues 행 수가 두 번 연속 같게 나올 때까지 폴링해서 배출 완료를 판단한다.
echo "Worker 배출 완료 대기 중 (coupon_issues row count 안정화 확인)..."
DRAIN_POLL_ATTEMPTS="${DRAIN_POLL_ATTEMPTS:-12}"
DRAIN_POLL_INTERVAL="${DRAIN_POLL_INTERVAL:-5}"
prev_count=""
for i in $(seq 1 "$DRAIN_POLL_ATTEMPTS"); do
  count=$(PGPASSWORD="$DB_PASSWORD" psql -X -A -t -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USERNAME" -d "$DB_DATABASE" \
    -c "SELECT count(*) FROM coupon_issues ci JOIN coupons c ON c.id = ci.coupon_id WHERE c.title LIKE '[k6-%';")
  if [ "$i" -gt 1 ] && [ "$count" = "$prev_count" ]; then
    echo "row count 유지됨(${count}건) — 배출 완료로 판단"
    break
  fi
  prev_count="$count"
  if [ "$i" -eq "$DRAIN_POLL_ATTEMPTS" ]; then
    echo "배출 대기 ${DRAIN_POLL_ATTEMPTS}회 시도 후에도 row count가 계속 늘어남 — 종단 지연 계산이 아직 처리 중인 요청을 놓칠 수 있습니다. scaleout처럼 백로그가 깊은 시나리오는 DRAIN_POLL_ATTEMPTS/DRAIN_POLL_INTERVAL을 늘려서 재실행하세요." >&2
    break
  fi
  sleep "$DRAIN_POLL_INTERVAL"
done

echo "종단 지연 계산 중 (requested_at -> issued_at, latency-report.sql)..."
mkdir -p "$K6_DIR/results"
LATENCY_OUT="$K6_DIR/results/${SCENARIO}-latency-$(date +%s).txt"
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USERNAME" -d "$DB_DATABASE" \
  -f "$SCRIPT_DIR/latency-report.sql" | tee "$LATENCY_OUT"

# k6가 끝나도, 그 시점에 백엔드가 이미 받아 처리 중이던 요청(위에서 기다린 큐 배출)은
# 클라이언트와 무관하게 계속 커밋된다. 그 커밋이 cleanup 중간에 끼어들면 FK 제약 위반으로
# 트랜잭션 전체가 롤백되므로, 백엔드 큐가 다 빌 때까지 몇 번 재시도한다.
echo "테스트 데이터 정리 중 (title LIKE '[k6-%')..."
CLEANUP_ATTEMPTS="${CLEANUP_ATTEMPTS:-5}"
CLEANUP_RETRY_DELAY="${CLEANUP_RETRY_DELAY:-10}"
for i in $(seq 1 "$CLEANUP_ATTEMPTS"); do
  if PGPASSWORD="$DB_PASSWORD" psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USERNAME" -d "$DB_DATABASE" \
    -f "$SCRIPT_DIR/cleanup.sql"; then
    break
  fi
  if [ "$i" -eq "$CLEANUP_ATTEMPTS" ]; then
    echo "정리 ${CLEANUP_ATTEMPTS}회 시도 후에도 실패 — 백엔드가 아직 이전 요청을 처리 중일 수 있습니다. 잠시 후 cleanup.sql을 직접 재실행하세요." >&2
    break
  fi
  echo "정리 실패 (백엔드가 아직 큐를 처리 중일 수 있음) — ${CLEANUP_RETRY_DELAY}초 후 재시도 (${i}/${CLEANUP_ATTEMPTS})..."
  sleep "$CLEANUP_RETRY_DELAY"
done

exit "$K6_EXIT"
