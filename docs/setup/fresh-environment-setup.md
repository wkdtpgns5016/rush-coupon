# 신규 환경 세팅 가이드

클론받은 상태에서, CI/CD가 끝까지 동작하는 상태로 새로 세팅할 때 필요한 절차입니다.

## 전제 조건

- Tailscale tailnet에 GitLab을 올릴 머신과 k8s 마스터/워커 노드가 이미 조인되어 있음
- kubeadm + containerd로 k8s 클러스터가 이미 구성되어 있음

## 1. Postgres (Docker, 외부 DB)

```bash
cd deploy/external-db
cp .env.example .env   # 값 채우기
docker compose up -d
```

## 2. k8s에서 그 Postgres에 접근할 수 있게 Endpoints/Service 적용 (deploy 브랜치)

```bash
cd k8s/database/overlays/local
cp db-connection.env.example db-connection.env   # EXTERNAL_DB_IP를 Postgres 호스트의 Tailscale IP로 채우기
kubectl apply -k .
```

## 3. imagePullSecret 생성 (GitLab Container Registry 인증)

GitLab에서 `read_registry` 권한의 토큰을 발급한 뒤:

```bash
kubectl create secret docker-registry gitlab-registry \
  --namespace=rush-coupon \
  --docker-server=<GITLAB_HOST>:5050 \
  --docker-username=<username> \
  --docker-password=<token> \
  --docker-email=noreply@example.com
```

## 4. k8s-worker containerd에 GitLab Registry를 insecure(HTTP) 레지스트리로 등록

worker 노드에 SSH로 접속해서:

```bash
sudo mkdir -p "/etc/containerd/certs.d/<GITLAB_HOST>_5050_"   # 콜론이 아니라 언더스코어로 인코딩! (100.113.87.50:5050 → 100.113.87.50_5050_)
sudo tee "/etc/containerd/certs.d/<GITLAB_HOST>_5050_/hosts.toml" <<'EOF'
server = "http://<GITLAB_HOST>:5050"

[host."http://<GITLAB_HOST>:5050"]
  capabilities = ["pull", "resolve"]
EOF
```

`/etc/containerd/config.toml`에서 `[plugins.'io.containerd.cri.v1.images'.registry]`의 `config_path`가 **단일 경로**인지 확인 (`/etc/containerd/certs.d:/etc/docker/certs.d`처럼 콜론으로 여러 경로를 join하면 containerd 2.x에서 무시되는 버그가 있었음 — 반드시 `config_path = '/etc/containerd/certs.d'`처럼 단일 경로로):

```bash
sudo systemctl restart containerd
```

## 5. ArgoCD에 backend Application 등록

`deploy` 브랜치를 보게 되어 있습니다 (`k8s/backend/argocd-application.yaml`도 그 브랜치에 있음):

```bash
git fetch origin deploy
kubectl apply -f <(git show origin/deploy:k8s/backend/argocd-application.yaml)
```

## 6. GitLab 서버 / Runner / 미러링 / CI 시크릿

- `deploy/gitlab/` 참고 — GitLab CE + GitLab Runner를 Docker Compose로 구성
- GitHub ↔ GitLab 미러링, Runner 등록, Container Registry 활성화, CI/CD Variables(`GITHUB_PAT`) 등은 `deploy/gitlab/docker-compose.yml`과 `.github/workflows/mirror-to-gitlab.yml`, `.gitlab-ci.yml` 참고

## 7. Frontend 정적 호스팅 (nginx + 컨테이너 내장 SSH)

`deploy/frontend`는 nginx에 sshd를 같이 띄운 컨테이너입니다. 맥북 계정으로 직접 SSH하지 않고, 컨테이너 전용 `deploy` 계정으로만 SSH가 허용되도록 격리되어 있습니다. `/releases`(배포 콘텐츠)는 named volume이라 컨테이너를 재생성해도 유지됩니다.

CI가 SSH로 접속할 전용 키페어를 생성합니다 (최초 1회, 패스프레이즈 없이):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gitlab_ci_frontend_deploy -N ""
```

```bash
cd deploy/frontend
cp .env.example .env
```

`.env`에 값 채우기:
- `DEPLOY_PUBLIC_KEY` = `cat ~/.ssh/gitlab_ci_frontend_deploy.pub` 출력 전체 (공개키라 git엔 안 올리고 여기 `.env`로만 관리, 컨테이너가 기동 시 `authorized_keys`로 씀)
- `FRONTEND_SSH_PORT` — `deploy/gitlab`의 `GITLAB_SSH_PORT`(기본 2222)와 겹치지 않는 값으로 (예: 2223)

```bash
docker compose up -d --build
```

GitLab CI/CD Variables:

- `FRONTEND_SSH_PRIVATE_KEY` (protected+masked) — GitLab masked variable은 개행 문자를 허용하지 않아서, 개인키를 base64로 한 줄 인코딩해서 등록해야 함:
  ```bash
  base64 -b 0 -i ~/.ssh/gitlab_ci_frontend_deploy | pbcopy
  ```
  (`.gitlab-ci.yml`에서 `base64 -d`로 디코드해서 씀)
- `FRONTEND_HOST` = `<GITLAB_HOST>` (같은 Tailscale IP)
- `FRONTEND_SSH_PORT` — `.env`에 넣은 값과 동일하게 (GitLab SSH 포트랑 겹치면 엉뚱하게 GitLab sshd로 접속 시도해서 `Permission denied`로 실패함 — 실제로 겪었던 문제)

SSH 유저(`deploy`)와 배포 경로(`/releases`)는 이미지에 고정되어 있어서 별도 변수가 필요 없습니다.
