#!/usr/bin/env bash
# run.sh의 클라우드 버전. k6 자체는 로컬에서 그대로 돌리고(백엔드가 CloudFront로
# 퍼블릭 노출돼 있어 문제없음), DB에 직접 붙어야 하는 후처리(Worker 배출 대기 →
# latency-report.sql → integrity-check.sql → cleanup.sql)만 cloud-postprocess.sh를
# 담은 일회성 Pod로 클러스터 안에서 실행한다 — RDS가 private subnet이라 로컬에서
# psql 직접 접속이 안 되기 때문 (schema-apply/db-credentials-apply와 같은 이유).
# DB 접속 정보는 그 Pod 안에서 db-credentials-job ServiceAccount(EKS Pod Identity)로
# RDS를 직접 describe해서 얻으므로, 이 스크립트는 DB_HOST 등을 몰라도 된다.
#
# CHECK_RABBITMQ_DRAIN(run.sh의 Worker 강제종료 장애 시나리오용)은 여기선 지원하지
# 않는다 — Amazon MQ는 관리형이라 rabbitmqctl로 브로커에 직접 못 붙는다.
#
# 사용법: scripts/run-cloud.sh <baseline|spike|scaleout> [k6 run에 넘길 추가 인자...]
# 예:     scripts/run-cloud.sh spike -e SPIKE_VUS=3000
set -uo pipefail

SCENARIO="${1:?사용법: scripts/run-cloud.sh <baseline|spike|scaleout> [k6 run 인자...]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_DIR="$(dirname "$SCRIPT_DIR")"
KUBE_CONTEXT="rush-coupon-cloud"
NAMESPACE="rush-coupon"
DB_INSTANCE_ID="${DB_INSTANCE_ID:-rush-coupon-cloud-postgres}"
POD_NAME="k6-postprocess"
CM_NAME="k6-postprocess-files"

command -v kubectl >/dev/null || { echo "에러: kubectl이 필요합니다"; exit 1; }

k6 run "$K6_DIR/scenarios/${SCENARIO}.js" "$@"
K6_EXIT=$?

echo ""
echo "클러스터 안에서 후처리(배출 대기 -> latency-report -> integrity-check -> cleanup) 실행 중..."

kubectl --context "$KUBE_CONTEXT" delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

kubectl --context "$KUBE_CONTEXT" create configmap "$CM_NAME" -n "$NAMESPACE" \
  --from-file=latency-report.sql="$SCRIPT_DIR/latency-report.sql" \
  --from-file=integrity-check.sql="$SCRIPT_DIR/integrity-check.sql" \
  --from-file=cleanup.sql="$SCRIPT_DIR/cleanup.sql" \
  --from-file=cloud-postprocess.sh="$SCRIPT_DIR/cloud-postprocess.sh" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null

kubectl --context "$KUBE_CONTEXT" run "$POD_NAME" -n "$NAMESPACE" --restart=Never --image=debian:12-slim \
  --overrides='
{
  "spec": {
    "serviceAccountName": "db-credentials-job",
    "containers": [{
      "name": "'"$POD_NAME"'",
      "image": "debian:12-slim",
      "command": ["sh", "/sql/cloud-postprocess.sh"],
      "env": [
        {"name": "DB_INSTANCE_ID", "value": "'"$DB_INSTANCE_ID"'"},
        {"name": "DRAIN_POLL_ATTEMPTS", "value": "'"${DRAIN_POLL_ATTEMPTS:-12}"'"},
        {"name": "DRAIN_POLL_INTERVAL", "value": "'"${DRAIN_POLL_INTERVAL:-5}"'"},
        {"name": "CLEANUP_ATTEMPTS", "value": "'"${CLEANUP_ATTEMPTS:-5}"'"},
        {"name": "CLEANUP_RETRY_DELAY", "value": "'"${CLEANUP_RETRY_DELAY:-10}"'"}
      ],
      "volumeMounts": [{"name": "sql", "mountPath": "/sql"}]
    }],
    "volumes": [{"name": "sql", "configMap": {"name": "'"$CM_NAME"'"}}]
  }
}' >/dev/null

echo "Pod 완료 대기 중..."
# scaleout처럼 DRAIN_POLL_ATTEMPTS/INTERVAL을 크게 올리면(예: 60*15s=15분) 이 대기도
# 그만큼 길어져야 한다 — 기본값은 넉넉히 잡아두고, 필요하면 POD_WAIT_ATTEMPTS로 늘린다.
POD_WAIT_ATTEMPTS="${POD_WAIT_ATTEMPTS:-180}"
PHASE=""
for i in $(seq 1 "$POD_WAIT_ATTEMPTS"); do
  PHASE="$(kubectl --context "$KUBE_CONTEXT" get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
  { [ "$PHASE" = "Succeeded" ] || [ "$PHASE" = "Failed" ]; } && break
  sleep 10
done

mkdir -p "$K6_DIR/results"
OUT="$K6_DIR/results/${SCENARIO}-cloud-postprocess-$(date +%s).txt"
kubectl --context "$KUBE_CONTEXT" logs "$POD_NAME" -n "$NAMESPACE" 2>&1 | tee "$OUT"

if [ "$PHASE" != "Succeeded" ]; then
  echo "경고: 후처리 Pod가 ${PHASE:-Unknown} 상태로 끝났습니다 — 위 로그를 확인하세요." >&2
fi

kubectl --context "$KUBE_CONTEXT" delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
kubectl --context "$KUBE_CONTEXT" delete configmap "$CM_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

exit "$K6_EXIT"
