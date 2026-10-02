#!/bin/sh
# run-cloud.sh가 올려보낸 일회성 Pod 안에서 돈다. run.sh의 2~5단계(Worker 배출 대기,
# latency-report.sql, integrity-check.sql, cleanup.sql)를 그대로 재현하되, RDS가
# private subnet이라 로컬에서 직접 psql로 못 붙으니 클러스터 안에서 실행한다.
# DB 접속 정보는 db-credentials-job ServiceAccount(EKS Pod Identity)로 RDS를 직접
# describe해서 얻는다 — schema-apply/db-credentials-apply와 같은 패턴.
#
# CHECK_RABBITMQ_DRAIN(run.sh의 Worker 강제종료 장애 시나리오용)은 여기서 지원하지
# 않는다 — rabbitmqctl은 브로커 노드에 직접 접속해야 하는데 Amazon MQ는 관리형이라
# 그 방식 자체가 안 된다. 필요하면 RabbitMQ 관리 HTTP API나 CloudWatch 지표로 별도
# 구현해야 한다(지금은 범위 밖).
set -eu

apt-get update -qq
apt-get install -y -qq curl unzip postgresql-client jq >/dev/null
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install >/dev/null
AWS=/usr/local/bin/aws

DB_INFO=$("$AWS" rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID")
DB_HOST=$(echo "$DB_INFO" | jq -r '.DBInstances[0].Endpoint.Address')
DB_PORT=$(echo "$DB_INFO" | jq -r '.DBInstances[0].Endpoint.Port')
DB_DATABASE=$(echo "$DB_INFO" | jq -r '.DBInstances[0].DBName')
SECRET_ARN=$(echo "$DB_INFO" | jq -r '.DBInstances[0].MasterUserSecret.SecretArn')
SECRET_JSON=$("$AWS" secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)
DB_USERNAME=$(echo "$SECRET_JSON" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r .password)
export PGPASSWORD="$DB_PASSWORD" PGSSLMODE=require

psql_cloud() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" "$@"
}

echo "Worker 배출 완료 대기 중 (coupon_issues row count 안정화 확인)..."
prev_count=""
for i in $(seq 1 "$DRAIN_POLL_ATTEMPTS"); do
  count=$(psql_cloud -X -A -t -c "SELECT count(*) FROM coupon_issues ci JOIN coupons c ON c.id = ci.coupon_id WHERE c.title LIKE '[k6-%';")
  if [ "$i" -gt 1 ] && [ "$count" = "$prev_count" ]; then
    echo "row count 유지됨(${count}건) — 배출 완료로 판단"
    break
  fi
  prev_count="$count"
  if [ "$i" -eq "$DRAIN_POLL_ATTEMPTS" ]; then
    echo "배출 대기 ${DRAIN_POLL_ATTEMPTS}회 시도 후에도 row count가 계속 늘어남 — 종단 지연 계산이 아직 처리 중인 요청을 놓칠 수 있습니다." >&2
    break
  fi
  sleep "$DRAIN_POLL_INTERVAL"
done

echo "종단 지연 계산 중 (requested_at -> issued_at, latency-report.sql)..."
psql_cloud -f /sql/latency-report.sql

echo "정합성 검증 중 (integrity-check.sql — 저장 건수/중복 발급/초과 발급)..."
psql_cloud -f /sql/integrity-check.sql

echo "테스트 데이터 정리 중 (title LIKE '[k6-%')..."
for i in $(seq 1 "$CLEANUP_ATTEMPTS"); do
  if psql_cloud -v ON_ERROR_STOP=1 -f /sql/cleanup.sql; then
    break
  fi
  if [ "$i" -eq "$CLEANUP_ATTEMPTS" ]; then
    echo "정리 ${CLEANUP_ATTEMPTS}회 시도 후에도 실패 — 백엔드가 아직 이전 요청을 처리 중일 수 있습니다." >&2
    break
  fi
  echo "정리 실패 (백엔드가 아직 큐를 처리 중일 수 있음) — ${CLEANUP_RETRY_DELAY}초 후 재시도 (${i}/${CLEANUP_ATTEMPTS})..."
  sleep "$CLEANUP_RETRY_DELAY"
done
