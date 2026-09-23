# 신규 환경 세팅 가이드

클론받은 상태에서, CI/CD가 끝까지 동작하는 상태로 새로 세팅할 때 필요한 절차입니다.

## 전제 조건

- Tailscale tailnet에 GitLab을 올릴 머신과 k8s 마스터/워커 노드가 이미 조인되어 있음
- kubeadm + containerd로 k8s 클러스터가 이미 구성되어 있음
- [setup-k8s-vm](https://github.com/wkdtpgns5016/setup-k8s-vm)의 `install-addons.sh`로 ingress-nginx, ArgoCD, **metrics-server, 모니터링 스택(kube-prometheus-stack)** 이 이미 설치되어 있음. 9번에서 등록하는 backend Application이 HPA(→ metrics-server)와 ServiceMonitor(→ kube-prometheus-stack의 CRD)를 함께 적용하므로, 이 두 애드온은 9번보다 먼저 있어야 합니다.

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

각 값은 다음을 채우면 됩니다:

| 키 | 넣을 값 | 설명 |
|---|---|---|
| `DB_HOST` | **`postgres-service`** (고정값) | 4번에서 만드는 `k8s/database/base/service.yaml`의 Service 이름. `rush-coupon` 네임스페이스 안이라 backend Pod에서 서비스명만으로 DNS 조회가 됩니다. **IP를 넣지 마세요** — 실제 Postgres 위치(Tailscale IP)는 4번의 Endpoints가 담당합니다. |
| `DB_PORT` | **`5432`** | k8s Service/Endpoints 포트가 5432로 고정되어 있습니다. 2번 `.env`의 `POSTGRES_PORT`를 5432가 아닌 값으로 바꿨다면 `k8s/database/base`의 포트도 같이 바꿔야 하고, 그 값을 여기에 넣어야 합니다. |
| `DB_DATABASE` | 2번 `deploy/external-db/.env`의 `POSTGRES_DB` | 예: `rush_coupon` |
| `DB_USERNAME` | 2번 `deploy/external-db/.env`의 `POSTGRES_USER` | 예: `coupon_user` |
| `DB_PASSWORD` | 2번 `deploy/external-db/.env`의 `POSTGRES_PASSWORD` | |

`DB_HOST`/`DB_PORT`는 k8s 안에서의 접속 경로(고정값)이고, 나머지 3개는 2번에서 만든 Postgres의 값과 동일해야 합니다.

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

이 Ingress는 `/coupons`와 `/`(배포 검증용)만 backend로 넘기는 **허용 목록** 방식입니다. Prometheus용 `/metrics`가 외부에 노출되지 않게 일부러 뺀 것이고, Prometheus는 Ingress를 거치지 않고 ServiceMonitor로 Pod에 직접 접근합니다. 그래서 **backend에 새 API 경로를 추가하면 `k8s/backend/local-network/ingress.yaml`에도 추가하고 `kubectl apply -k .`를 다시 실행**해야 외부에서 호출됩니다. ("`/metrics`만 차단"하는 방식은 쓰면 안 됩니다. nginx는 경로 대소문자를 구분하지만 Express는 구분하지 않아서 `/Metrics`, `/metrics/`로 우회됩니다.)

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

레포 Settings > Secrets and variables > Actions에서 등록합니다. 이 값들은 `.github/workflows/mirror-to-gitlab.yml`(GitHub `main` → GitLab 미러링)이 씁니다.

**Secrets** (Secrets 탭 > New repository secret):

| 이름 | 넣을 값 | 용도 |
|---|---|---|
| `GITLAB_DEPLOY_TOKEN` | 6-1 끝에 출력된 `GITLAB_DEPLOY_TOKEN` | GitLab에 push할 때 쓰는 mirror 토큰 (`write_repository`) |
| `GITLAB_DEPLOY_USER` | 6-1 끝에 출력된 `GITLAB_DEPLOY_USER` | 위 토큰의 bot 유저명 |
| `TS_AUTHKEY` | Tailscale auth key | GitHub Actions 러너가 tailnet에 붙어 사설 IP의 GitLab에 닿게 함 |

`TS_AUTHKEY`는 Tailscale 관리 콘솔(Settings > Keys > Generate auth key)에서 발급합니다. 러너는 실행할 때마다 새 노드로 조인하므로 **Reusable**, 끝나면 노드가 자동 정리되도록 **Ephemeral**을 켭니다. Reusable이 꺼진 키는 한 번 쓰면 다음 실행부터 Tailscale 연결 단계에서 실패합니다. 키에는 만료 기간이 있으니, 나중에 미러링이 Tailscale 연결에서 실패하면 새 키로 교체하세요.

**Variables** (Variables 탭 > New repository variable — 비밀값이 아니라 Variables에 등록):

| 이름 | 넣을 값 | 용도 |
|---|---|---|
| `GITLAB_HOST` | `deploy/gitlab/.env`의 `GITLAB_HOST` (GitLab 올린 머신의 Tailscale IP, 포트 없이) | Tailscale 연결 확인(ping) + push 대상 주소 |
| `GITLAB_PROJECT_PATH` | `root/rush-coupon` | push 대상 프로젝트 경로 (`http://<GITLAB_HOST>/<GITLAB_PROJECT_PATH>`) |

GitLab 머신의 IP가 안 바뀌었다면 기존 값 그대로 둬도 됩니다. 여기서는 등록만 하고, 실제 미러링 실행은 10번에서 합니다.

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

이 Application은 Deployment/Service 외에 **HPA**(`k8s/backend/base/hpa.yaml`, 2~10개)와 **ServiceMonitor**(`servicemonitor.yaml`)도 함께 적용합니다. 그래서 전제 조건의 metrics-server / 모니터링 스택이 없으면 동기화가 실패하거나 HPA가 동작하지 않습니다. Deployment에는 `replicas`를 일부러 두지 않았는데, 두면 ArgoCD selfHeal이 HPA가 조정한 값을 계속 되돌리기 때문입니다.

## 10. GitHub → GitLab 미러링 실행 및 배포 검증

9번(ArgoCD Application 등록)까지 끝난 뒤에 진행합니다.

### 10-1. 미러링 실행 (workflow_dispatch)

`main`에 push하면 자동으로 미러링되지만, 세팅 직후에는 push가 없어서 GitLab 프로젝트가 비어 있습니다. GitHub Actions에서 수동으로 한 번 실행합니다:

1. GitHub 레포 > **Actions** 탭 > 왼쪽 목록에서 **Mirror to GitLab** 선택
2. 오른쪽 **Run workflow** 버튼 > 브랜치 `main` 확인 > **Run workflow**
3. 실행이 초록색(성공)이 되면 `http://<GITLAB_HOST>`(root / `GITLAB_ROOT_PASSWORD`)의 rush-coupon 프로젝트에 코드가 올라온 것을 확인

`--force` push라 GitLab의 `main`은 항상 GitHub `main`과 같은 내용으로 덮어써집니다. 실패했다면:
- **Connect to Tailscale** 단계 실패 → `TS_AUTHKEY` (Reusable 여부, 만료)
- **Push to GitLab** 단계 실패 → `GITLAB_DEPLOY_TOKEN`/`GITLAB_DEPLOY_USER`, `GITLAB_HOST`, `GITLAB_PROJECT_PATH`

### 10-2. GitLab 파이프라인 실행

미러링되면 GitLab 프로젝트 > Build > Pipelines에 파이프라인이 생깁니다.

- lint / test / build job은 자동 실행됩니다.
- `backend-deploy`, `frontend-deploy`는 **수동(manual) job**입니다. build가 끝난 뒤 각 job의 ▶ 버튼을 눌러 실행하세요.
- `.gitlab-ci.yml`의 `workflow.rules` 때문에 `backend/`, `frontend/`, `.gitlab-ci.yml` 중 하나라도 바뀐 커밋에서만 파이프라인이 만들어집니다. 안 보이면 이 경로에 변경이 없는 커밋이라 그런 것입니다.

`backend-deploy`는 외부 DB에 `schema.sql`을 적용하고, `deploy` 브랜치의 `k8s/backend/overlays/local/image.env` 이미지 태그를 새 커밋으로 갱신해 push합니다. 그러면 ArgoCD가 변경을 감지해 롤아웃합니다. `frontend-deploy`는 빌드 결과를 frontend 컨테이너의 `/releases/dist-<커밋>-<job id>`에 올리고 `/releases/current` 심볼릭 링크를 그쪽으로 바꿉니다.

### 10-3. 배포 검증

아래에서 이번에 배포한 커밋의 태그는 `git rev-parse --short=8 HEAD`(GitHub `main` 최신 커밋 앞 8자리)로 확인합니다.

**backend**

```bash
# 1. ArgoCD가 반영했는지 (SYNC STATUS=Synced, HEALTH STATUS=Healthy)
kubectl -n argocd get application backend

# 2. 배포된 이미지 태그가 이번 커밋과 같은지
kubectl -n rush-coupon get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# 3. 롤아웃 완료 / Pod Running (HPA minReplicas가 2라서 Pod가 2개 뜸)
kubectl -n rush-coupon rollout status deploy/backend
kubectl -n rush-coupon get pods

# 4. 실제 응답 (Ingress → Service → Pod)
curl http://<INGRESS_HOST>/        # Hello World!
```

ArgoCD는 기본적으로 몇 분 간격(기본 3분)으로 `deploy` 브랜치를 확인하므로, 2번에서 태그가 아직 이전 값이면 잠시 기다리거나 ArgoCD UI에서 Refresh 하세요.

DB 연결까지 확인하려면 시드 쿠폰의 id를 조회해서 호출합니다:

```bash
docker exec rush-coupon-postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB> -c "select id, title from coupons;"
curl http://<INGRESS_HOST>/coupons/<위에서 조회한 id>
```

JSON이 응답되면 backend → `postgres-service` → 외부 Postgres 경로가 모두 정상입니다.

**frontend**

```bash
# 1. current 링크가 이번 커밋의 릴리스를 가리키는지 (current -> dist-<커밋 앞 8자리>-<job id>)
docker exec rush-coupon-frontend ls -l /releases

# 2. 웹 응답
curl -I http://<FRONTEND_HOST>:<FRONTEND_PORT>/     # HTTP/1.1 200 OK
```

브라우저에서 `http://<FRONTEND_HOST>:<FRONTEND_PORT>`에 접속해 화면이 뜨는지, 개발자도구 Network 탭에서 API 요청이 `http://<INGRESS_HOST>`로 나가 200으로 응답하는지(CORS 에러가 없는지)까지 봅니다.

**문제가 생겼을 때**

| 증상 | 확인할 곳 |
|---|---|
| `backend-build`의 push 단계 실패 (`HTTP response to HTTPS client` 등) | 6-3 Container Registry insecure 등록 |
| Pod가 `ImagePullBackOff` | 8번 containerd insecure 등록, `gitlab-registry` Secret (6-1) |
| Pod가 `CrashLoopBackOff` + DB 연결 에러 | `kubectl -n rush-coupon logs deploy/backend`, 3번 Secret 값, 4번 Endpoints IP |
| ArgoCD 동기화 실패 `no matches for kind "ServiceMonitor"` | 모니터링 스택 설치 여부 (`kubectl get crd servicemonitors.monitoring.coreos.com`) |
| HPA `TARGETS`가 `<unknown>` | metrics-server 설치 여부 (`kubectl top nodes`가 동작해야 함) |
| `curl http://<INGRESS_HOST>/`가 404/502 | 5번 `INGRESS_HOST` 값, Pod Ready 여부 |
| 브라우저에서 CORS 에러 | 5번 `CORS_ORIGIN`이 `http://<FRONTEND_HOST>:<FRONTEND_PORT>`와 정확히 일치하는지 |
| `frontend-deploy`가 SSH에서 `Permission denied` | 1번 `FRONTEND_SSH_PORT`가 GitLab SSH 포트와 겹치지 않는지, 키 |

## 11. 모니터링 대시보드 적용 및 수집/HPA 확인 (deploy 브랜치)

Prometheus/Grafana 자체는 전제 조건의 `install-addons.sh`가 이미 설치했습니다. 여기서는 rush-coupon 전용 조각만 붙입니다. ServiceMonitor(backend `/metrics` 15초 수집)와 HPA는 9번의 ArgoCD Application이 이미 적용했고, 남은 것은 Grafana 대시보드뿐입니다. 대시보드는 ArgoCD 추적 대상이 아니라 직접 `kubectl apply -k` 합니다 (4·5번과 같은 방식):

```bash
cd k8s/monitoring
kubectl apply -k .
```

Grafana 사이드카가 잠시 뒤 **Rush Coupon API** 대시보드를 자동으로 읽습니다. 접속 정보는 `install-addons.sh` 출력에 있고, 비밀번호는 다음으로도 확인할 수 있습니다:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**수집 확인**

```bash
kubectl -n rush-coupon get servicemonitor backend
```

Prometheus UI(`http://prometheus.<IP>.nip.io/targets`)에서 `rush-coupon/backend`가 **UP**이어야 합니다. 대시보드의 HTTP 패널(RPS, P95/P99, 발급 결과 분포)은 backend에 요청이 들어와야 채워지니, 10-3의 `curl`을 몇 번 호출한 뒤 봅니다. 노드/Pod 리소스 패널은 kubelet(cAdvisor)·kube-state-metrics·node-exporter 지표를 쓰므로 별도 설정 없이 나옵니다.

`/metrics`가 Ingress로 외부에 노출되지 않는지도 확인합니다. 아래는 모두 404여야 하고, 반대로 API는 정상 응답해야 합니다:

```bash
for p in /metrics /Metrics /metrics/; do curl -s -o /dev/null -w "$p -> %{http_code}\n" http://<INGRESS_HOST>$p; done
curl -s -o /dev/null -w "/coupons/<id> -> %{http_code}\n" http://<INGRESS_HOST>/coupons/<id>   # 200
```

`/targets`에 backend가 아예 없거나 DOWN이면, 배포된 backend 이미지가 `/metrics`를 제공하는 커밋 이후의 것인지(10-3 2번의 이미지 태그)부터 확인하세요.

**DB 지표 확인** — 대시보드의 "데이터베이스" 행은 postgres-exporter가 채웁니다. 9번의 `backend` Application이 이 exporter도 함께 배포하고, backend와 같은 시크릿(`backend-db-credentials`)으로 외부 Postgres에 접속하므로 별도 설정은 없습니다:

```bash
kubectl -n rush-coupon get pods -l app=postgres-exporter    # 1/1 Running
```

Prometheus UI(`/targets`)에서 `rush-coupon/postgres-exporter`가 **UP**이고, Graph에서 `pg_up`이 `1`이어야 합니다. `0`이거나 Pod가 `Running`이 아니면 `kubectl -n rush-coupon logs deploy/postgres-exporter`로 접속 오류(3번 Secret 값, 4번 Endpoints)를 확인하세요.

**HPA 확인**

```bash
kubectl top nodes
kubectl -n rush-coupon get hpa backend    # TARGETS가 <unknown>이 아니라 cpu: N%/70%, memory: N%/80% 로 보여야 함
```

- 두 사용률은 모두 **requests(CPU 100m / 메모리 128Mi) 대비**입니다. Node.js 앱은 idle에서도 메모리를 100Mi 안팎 쓸 수 있어, 메모리 80% 기준 때문에 부하 없이도 스케일 아웃할 수 있습니다. 첫 배포 후 `kubectl top pod -n rush-coupon`으로 idle 사용량을 확인하세요.
- Prometheus 스토리지가 `emptyDir`(retention 3d)이라 Prometheus Pod가 재시작되면 지표가 사라집니다. 부하 테스트 결과는 그 전에 캡처해 두세요.

패널 구성과 자세한 설명은 `deploy` 브랜치의 `k8s/monitoring/README.md`를 참고하세요.
