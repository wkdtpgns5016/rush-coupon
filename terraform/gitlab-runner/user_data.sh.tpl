#!/usr/bin/env bash
set -euo pipefail

# Docker (공식 설치 스크립트 — Ubuntu 22.04 apt의 docker.io는 compose v2 플러그인이 빠져있음)
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# Tailscale authkey를 SSM Parameter Store에서 조회 (user_data/인스턴스 메타데이터엔
# 평문으로 남기지 않기 위함 — IAM 인스턴스 프로파일이 이 파라미터 하나만 읽을 권한을 갖는다)
apt-get update -y
apt-get install -y awscli

# 방금 붙인 IAM 인스턴스 프로파일이 AWS 내부에 완전히 전파되기까지 짧은 지연이 있을 수 있어서
# (흔히 보고되는 EC2 신규 인스턴스의 자격증명 전파 지연) 재시도 루프로 감싼다.
# 여기서 실패하면 tailscale 조인까지 못 가서 인스턴스가 아예 고립되므로 반드시 필요하다.
TAILSCALE_AUTHKEY=""
for i in $(seq 1 10); do
  TAILSCALE_AUTHKEY=$(aws ssm get-parameter \
    --name "${ssm_parameter_name}" \
    --with-decryption \
    --region "${region}" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null) && break
  sleep 6
done
[ -n "$TAILSCALE_AUTHKEY" ]

curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey="$${TAILSCALE_AUTHKEY}" --hostname="${hostname}"

# GitLab Container Registry가 평문 HTTP라서(TLS는 tailnet 암호화로 대체, 기존 온프레미스와 동일한 결정),
# 이 인스턴스 자신의 docker 데몬에 insecure-registries로 예외 등록해야
# backend-build 잡의 docker login/push가 "HTTPS 기대했는데 HTTP 응답" 에러 없이 된다.
# GitLab+Runner가 이 EC2로 옮겨오면서, 예전엔 Mac의 Docker Desktop에 해줬던 설정이
# 이제는 이 인스턴스 자신에게 필요해졌다.
MY_TAILSCALE_IP=$(tailscale ip -4)
echo "{\"insecure-registries\": [\"$${MY_TAILSCALE_IP}:${gitlab_registry_port}\"]}" > /etc/docker/daemon.json
systemctl restart docker
