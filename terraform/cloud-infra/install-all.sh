#!/usr/bin/env bash
# terraform apply 이후 애드온 설치 스크립트들을 올바른 순서로 한 번에 실행한다.
#
# 순서가 중요하다 — eso/alb-controller/metrics-server/monitoring을 전부 끝낸 뒤에
# argocd를 설치해야, 나중에 argocd-application-cloud.yaml을 적용할 때 ExternalSecret
# (ESO CRD)/Ingress(ALB controller)/ServiceMonitor(monitoring CRD)가 전부 준비돼 있어서
# 수동 재sync 없이 한 번에 Synced/Healthy로 끝난다 (설치 순서를 지키지 않아서 겪은
# 문제는 argocd-application-cloud.yaml의 주석 참고).
# - alb-controller -> monitoring은 install-monitoring.sh 자체가 강제 체크한다.
# - 그 외 순서는 이 스크립트가 강제한다.
#
# 각 install-*.sh는 멱등(이미 설치돼 있으면 [SKIP])이라 중간에 실패해서 재실행해도
# 안전하다.
#
# 사용법: ./install-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "######################################################################"
echo "# 1/7 External Secrets Operator"
echo "######################################################################"
"${SCRIPT_DIR}/install-eso.sh"

echo ""
echo "######################################################################"
echo "# 2/7 AWS Load Balancer Controller"
echo "######################################################################"
"${SCRIPT_DIR}/install-alb-controller.sh"

echo ""
echo "######################################################################"
echo "# 3/7 metrics-server"
echo "######################################################################"
"${SCRIPT_DIR}/install-metrics-server.sh"

echo ""
echo "######################################################################"
echo "# 4/7 모니터링 스택 (Prometheus Operator / Grafana)"
echo "######################################################################"
"${SCRIPT_DIR}/install-monitoring.sh"

echo ""
echo "######################################################################"
echo "# 5/7 ArgoCD"
echo "######################################################################"
"${SCRIPT_DIR}/install-argocd.sh"

echo ""
echo "######################################################################"
echo "# 6/7 backend 앱 배포 (대시보드 + ArgoCD Application)"
echo "######################################################################"
"${SCRIPT_DIR}/bootstrap-backend-app.sh"

echo ""
echo "######################################################################"
echo "# 7/7 backend용 CloudFront (HTTPS, Mixed Content 방지)"
echo "######################################################################"
# backend ALB(http)가 이제 막 생겼으니, backend-cdn.tf의 count 게이트를 열고
# 바로 전 apply(테라폼이 모르던 ALB가 생기기 전)와 분리된 두 번째 apply로 완성한다.
# auto.tfvars로 저장해야 다음에 아무 옵션 없이 plan/apply해도 이 값이 유지된다
# (teardown.sh가 destroy 뒤 이 파일을 지워서 다음 첫 apply는 다시 false로 돌아간다).
echo 'enable_backend_cdn = true' > "${SCRIPT_DIR}/backend-cdn.auto.tfvars"
terraform -chdir="$SCRIPT_DIR" apply -auto-approve

echo ""
echo "=================================================================="
echo " [클라우드 환경 구성 전체 완료]"
echo "   backend_cdn_url: $(terraform -chdir="$SCRIPT_DIR" output -raw backend_cdn_url)"
echo "=================================================================="
