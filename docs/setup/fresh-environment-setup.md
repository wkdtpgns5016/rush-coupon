# 신규 환경 세팅 가이드

클론받은 상태에서, CI/CD가 끝까지 동작하는 상태로 새로 세팅할 때 필요한 절차입니다.

## 전제 조건

- Tailscale tailnet에 GitLab을 올릴 머신과 k8s 마스터/워커 노드가 이미 조인되어 있음
- kubeadm + containerd로 k8s 클러스터가 이미 구성되어 있음

## 1. Frontend 정적 호스팅 (nginx + 컨테이너 내장 SSH)

다른 어떤 스텝에도 의존하지 않는 독립적인 컨테이너라 제일 먼저 띄웁니다. `deploy/frontend`는 nginx에 sshd를 같이 띄운 컨테이너입니다. 맥북 계정으로 직접 SSH하지 않고, 컨테이너 전용 `deploy` 계정으로만 SSH가 허용되도록 격리되어 있습니다. `/releases`(배포 콘텐츠)는 named volume이라 컨테이너를 재생성해도 유지됩니다.

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

GitLab이 아직 없어서 CI/CD Variables 등록은 지금 못합니다 — 아래 값들은 적어뒀다가 7번(GitLab CI/CD Variables)에서 `deploy/gitlab/.env`에 채워 넣으세요:
- `FRONTEND_HOST` = GitLab을 올릴 머신의 Tailscale IP (이 컨테이너와 같은 머신이면 동일한 IP)
- `FRONTEND_SSH_PORT` — 위 `.env`에 넣은 값과 동일하게 (나중에 GitLab SSH 포트랑 겹치면 엉뚱하게 GitLab sshd로 접속 시도해서 `Permission denied`로 실패함 — 실제로 겪었던 문제)
- `FRONTEND_SSH_KEY_PATH` = `~/.ssh/gitlab_ci_frontend_deploy` (7번 스크립트가 이 경로의 개인키를 base64로 인코딩해서 등록함, `.gitlab-ci.yml`에서 `base64 -d`로 디코드해서 씀 — GitLab masked variable은 개행 문자를 허용하지 않아서 base64가 필요)

SSH 유저(`deploy`)와 배포 경로(`/releases`)는 이미지에 고정되어 있어서 별도 변수가 필요 없습니다.

## 2. Postgres (Docker, 외부 DB)

```bash
cd deploy/external-db
cp .env.example .env   # 값 채우기
docker compose up -d
```

`docker-entrypoint-initdb.d`에 `backend/db/schema.sql`/`seed.sql`이 마운트되어 있어서, 위 `docker compose up -d`(볼륨이 비어있는 최초 1회)에 스키마+테스트용 시드 데이터가 자동으로 들어갑니다. 이후 스키마가 바뀌면(볼륨이 이미 있는 상태) GitLab CI의 `backend-deploy` job이 배포할 때마다 `schema.sql`을 다시 적용해줍니다(`CREATE TABLE IF NOT EXISTS`라 멱등성 있음) — `seed.sql`은 멱등성이 없어서 이 자동 재적용 대상에는 포함하지 않습니다.

## 3. backend DB credentials Secret 생성

`k8s/backend/base/deployment.yaml`이 `secretKeyRef`로 참조하는 시크릿입니다. 2번에서 만든 Postgres 접속 정보만 있으면 됩니다 (`rush-coupon` 네임스페이스가 아직 없을 수 있어 같이 생성):

```bash
kubectl create namespace rush-coupon --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic backend-db-credentials \
  --namespace=rush-coupon \
  --from-literal=DB_HOST=<postgres_service_name> \
  --from-literal=DB_PORT=<db_port> \
  --from-literal=DB_DATABASE=<db_name> \
  --from-literal=DB_USERNAME=<db_user> \
  --from-literal=DB_PASSWORD=<db_password>
```

(2번에서 만든 Postgres의 접속 정보와 동일해야 합니다.)

## 4. k8s에서 그 Postgres에 접근할 수 있게 Endpoints/Service 적용 (deploy 브랜치)

```bash
cd k8s/database/overlays/local
cp db-connection.env.example db-connection.env   # EXTERNAL_DB_IP를 Postgres 호스트의 Tailscale IP로 채우기
kubectl apply -k .
```

## 5. backend Ingress 호스트 값 채우기 (deploy 브랜치)

`k8s/backend/local-network`는 ArgoCD `backend` Application이 추적하는 `overlays/local`과 별개의 kustomize 경로입니다 — 이미지 태그처럼 계속 바뀌는 게 아니라 클러스터를 새로 만들 때만 바뀌는 값(Ingress 호스트, CORS 허용 origin)이라서, ArgoCD의 selfHeal이 덮어쓰지 못하게 아예 추적 대상에서 뺐습니다. 그래서 **git 커밋/푸시가 필요 없고**, `kubectl apply -k`로 직접 적용하면 끝입니다:

```bash
cd k8s/backend/local-network
cp network-connection.env.example network-connection.env
```

```
INGRESS_HOST=backend.<k8s-worker의 Tailscale IP>.nip.io
CORS_ORIGIN=http://<1번 Frontend를 올린 머신의 Tailscale IP>:<1번에서 정한 FRONTEND_PORT>
```

```bash
kubectl apply -k .
```

(`ingress-nginx`/ArgoCD 자체는 전제 조건에서 이미 설치되어 있다고 가정합니다. ArgoCD 서버의 Ingress 예시(`argocd.<worker-ip>.nip.io`)와 동일한 패턴입니다.)

## 6. GitLab 서버 / Runner / 미러링

### 6-1. GitLab + Runner 기동 (+ 자동 부트스트랩)

```bash
cd deploy/gitlab
cp .env.example .env   # GITLAB_ROOT_PASSWORD만 채우면 나머지(HOST=이 머신의 Tailscale IP)는 예시값 그대로 써도 됨
./up.sh
```

`docker compose up -d` 하고, GitLab이 healthy 되면 이어서 프로젝트 생성 → Access Token(mirror/registry-read) 발급 → `imagePullSecret` 생성 → Runner 등록까지 `up.sh`가 대화형으로 물어본 뒤 자동 실행합니다 (`./up.sh --bootstrap`으로 안 물어보고 바로 진행 가능, `./script/bootstrap-gitlab.sh`만 따로 재실행도 가능). 완전히 새 인스턴스에서 **한 번만** 실행하는 용도라 재실행하면 토큰/러너가 중복 생성됩니다.

끝나면 `TOKEN`/`PROJECT_ID`가 `deploy/gitlab/.env`에 자동 저장되고, 화면에 `GITLAB_DEPLOY_TOKEN`/`GITLAB_DEPLOY_USER` 값이 출력됩니다 (다음 스텝에 씀). 스크립트 내부 로직(부트스트랩 PAT 발급, 프로젝트/토큰 생성 API 호출, `gitlab-registry` imagePullSecret 생성 등)은 `deploy/gitlab/script/bootstrap-gitlab.sh` 참고.

### 6-2. GitHub Actions Secrets/Variables 갱신

레포 Settings > Secrets and variables > Actions:

- Secrets: `GITLAB_DEPLOY_TOKEN`/`GITLAB_DEPLOY_USER` = 6-1에서 출력된 값, `TS_AUTHKEY`(Tailscale ephemeral auth key)
- Variables: `GITLAB_HOST`, `GITLAB_PROJECT_PATH`(`root/rush-coupon`) — 이 머신 IP가 안 바뀌었다면 기존 값 그대로 둬도 됨

### 6-3. Container Registry insecure 등록 (이 Mac)

`~/.docker/daemon.json`에 `"insecure-registries": ["<GITLAB_HOST>:5050"]` 추가 후 Docker Desktop 재시작.

## 7. GitLab CI/CD Variables

1(Frontend), 2(Postgres), 5(Ingress), 6(GitLab) 모두 끝난 상태라 이제 한 번에 다 채울 수 있습니다. `deploy/gitlab/.env`에:

- `GITHUB_PAT`
- `EXTERNAL_DB_HOST`/`PORT`/`NAME`/`USER`/`PASSWORD` — `backend-deploy` job이 배포할 때마다 외부 DB에 `schema.sql`을 적용할 때 씀 (2번에서 만든 Postgres 접속 정보와 동일)
- `VITE_API_BASE_URL` = `http://<5번에서 정한 INGRESS_HOST>` — `frontend-build` job이 프로덕션 빌드에 주입. 값이 없으면 빌드 자체가 실패하도록 되어 있음(`frontend/vite.config.ts`) — localhost로 조용히 폴백되는 걸 방지하기 위함
- `FRONTEND_HOST`/`FRONTEND_SSH_PORT`/`FRONTEND_SSH_KEY_PATH` — 1번에서 적어둔 값

```bash
cd deploy/gitlab
./script/register-ci-variables.sh
```

값이 없는 항목은 자동으로 건너뛰니, 나중에 값이 바뀌어도 다시 실행하면 안전합니다.

## 8. k8s-worker containerd에 GitLab Registry를 insecure(HTTP) 레지스트리로 등록

worker 노드가 새로 만들어진 VM이면 SSH 호스트 키가 바뀌어서 접속이 막힐 수 있습니다 (`Host key verification failed`):

```bash
ssh-keygen -R k8s-worker   # 필요할 때만
ssh k8s-worker
```

접속 후, 아래 두 가지를 **둘 다** 해야 합니다 — 하나만 하면 동작 안 함:

**8-1. 이 레지스트리 전용 override 파일 생성** (containerd한테 "이 호스트는 HTTPS 대신 HTTP로 접속해라"를 알려줌):

```bash
sudo mkdir -p "/etc/containerd/certs.d/<GITLAB_HOST>_5050_"   # 콜론이 아니라 언더스코어로 인코딩! (100.113.87.50:5050 → 100.113.87.50_5050_)
sudo tee "/etc/containerd/certs.d/<GITLAB_HOST>_5050_/hosts.toml" <<'EOF'
server = "http://<GITLAB_HOST>:5050"

[host."http://<GITLAB_HOST>:5050"]
  capabilities = ["pull", "resolve"]
EOF
```

**8-2. `config_path`가 단일 경로인지 확인/수정** (containerd한테 "저 override 파일들을 어디서 찾을지" 알려줌 — 여기가 잘못돼 있으면 8-1이 있어도 containerd가 아예 안 읽음):

```bash
grep -n -B2 "config_path" /etc/containerd/config.toml
```

`[plugins.'io.containerd.cri.v1.images'.registry]` 섹션 바로 아래의 `config_path` 줄 번호(`<N>`)를 찾아서 (다른 섹션에도 `config_path`가 있을 수 있으니 주의), `/etc/containerd/certs.d:/etc/docker/certs.d`처럼 콜론으로 여러 경로를 join해놨다면 (containerd 2.x에서 이 형식은 통째로 무시되는 버그가 있음) 단일 경로로 고칩니다:

```bash
sudo sed -i "<N>s|.*|      config_path = '/etc/containerd/certs.d'|" /etc/containerd/config.toml
```

**8-3. 적용:**

```bash
sudo systemctl restart containerd
```

## 9. ArgoCD에 backend Application 등록

`deploy` 브랜치를 보게 되어 있습니다 (`k8s/backend/argocd-application.yaml`도 그 브랜치에 있음). 3번(DB credentials Secret), 5번(Ingress 호스트)이 먼저 끝나 있어야 첫 동기화가 깨지지 않습니다:

```bash
git fetch origin deploy
kubectl apply -f <(git show origin/deploy:k8s/backend/argocd-application.yaml)
```
