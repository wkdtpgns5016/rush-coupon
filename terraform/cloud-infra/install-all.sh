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
echo "# 1/6 External Secrets Operator"
echo "######################################################################"
"${SCRIPT_DIR}/install-eso.sh"

echo ""
echo "######################################################################"
echo "# 2/6 AWS Load Balancer Controller"
echo "######################################################################"
"${SCRIPT_DIR}/install-alb-controller.sh"

echo ""
echo "######################################################################"
echo "# 3/6 metrics-server"
echo "######################################################################"
"${SCRIPT_DIR}/install-metrics-server.sh"

echo ""
echo "######################################################################"
echo "# 4/6 모니터링 스택 (Prometheus Operator / Grafana)"
echo "######################################################################"
"${SCRIPT_DIR}/install-monitoring.sh"

echo ""
echo "######################################################################"
echo "# 5/6 ArgoCD"
echo "######################################################################"
"${SCRIPT_DIR}/install-argocd.sh"

echo ""
echo "######################################################################"
echo "# 6/6 backend 앱 배포 (대시보드 + ArgoCD Application)"
echo "######################################################################"
"${SCRIPT_DIR}/bootstrap-backend-app.sh"

echo ""
echo "=================================================================="
echo " [클라우드 환경 구성 전체 완료]"
echo "=================================================================="
