# gitlab-runner (M6 #54)

GitLab CE + Runner를 AWS EC2로 옮겨서, 새 EKS 스택을 기다리지 않고 "GitLab이 AWS에 있어도 기존 온프레미스 클러스터 대상 CI/CD 파이프라인이 문제없이 도는가"를 검증하기 위한 스택이다. 전용 VPC(10.60.0.0/16)를 새로 만들며, #55의 EKS용 VPC와는 별개다 — 두 스택이 동시에 떠 있을 필요가 없어서 NAT Gateway를 공유할 이유가 없다.

## 구성

- 전용 VPC + 퍼블릭 서브넷(NAT Gateway) + 프라이빗 서브넷(EC2)
- GitLab+Runner EC2 (Ubuntu 22.04, t3.large) — 프라이빗 서브넷, 퍼블릭 IP 없음
- 부팅 시 user_data로 Docker 설치 + SSM Parameter Store에서 Tailscale authkey를 가져와 tailnet 조인까지 자동화 (authkey는 ephemeral 변수 + write-only 인자라 state/user_data 어디에도 평문으로 안 남음)
- EC2에 ECR push 권한(`AmazonEC2ContainerRegistryPowerUser`, 계정 전체)을 주는 IAM 역할 — ECR 리포지토리 자체는 `terraform/cloud-infra`(#55)에 있다. 이 스택처럼 자주 스핀업/destroy되는 곳에 리포지토리를 두면 destroy할 때마다 이미지가 같이 사라져서, EKS가 있는 영구적인 스택으로 옮겼다
- 보안그룹은 아웃바운드만 허용한다. 프라이빗 서브넷이라 인터넷發 인바운드가 라우팅 단계에서부터 불가능하고, SSH도 Tailscale(아웃바운드로 시작되는 세션의 stateful 리턴 트래픽)로만 붙기 때문에 인그레스 규칙 자체가 필요 없다
- `bootstrap-and-verify.sh` — apply 이후 실행하는 오케스트레이션 스크립트. Tailscale에 인스턴스가 뜰 때까지 기다렸다가, `DOCKER_HOST=ssh://ubuntu@<tailscale-ip>`로 docker 명령만 원격 조준해서 기존 `deploy/gitlab/` 스크립트를 그대로 재사용한다. kubectl/curl/GITHUB_PAT 등은 계속 이 Mac에서 실행되므로 온프레미스 클러스터의 kubeconfig나 GITHUB_PAT/DB비밀번호/SSH키가 EC2로 전혀 넘어가지 않는다

## 적용

```bash
cd terraform/gitlab-runner
cp terraform.tfvars.example terraform.tfvars   # ssh_public_key, tailscale_authkey 채우기
terraform init
terraform plan
terraform apply && ./bootstrap-and-verify.sh
```

`bootstrap-and-verify.sh`가 자동으로 하는 것:

1. Tailscale에 인스턴스가 Online으로 뜰 때까지 폴링
2. `deploy/gitlab/.env`의 `GITLAB_HOST`/`GITLAB_EXTERNAL_URL`을 새 Tailscale IP로 갱신
3. SSH 접속 가능해질 때까지 대기
4. `DOCKER_HOST`로 `up.sh --bootstrap` 실행 (GitLab+Runner 배포, 프로젝트/토큰/Runner 등록, 온프레미스 클러스터에 ECR용 imagePullSecret 생성까지 — kubectl은 로컬 kubeconfig로 실행됨)
5. `register-ci-variables.sh` 실행 (GitLab CI/CD Variables 등록)
6. `gh variable set GITLAB_HOST` / `gh secret set GITLAB_DEPLOY_USER,GITLAB_DEPLOY_TOKEN`으로 GitHub Actions 쪽도 자동 갱신
7. `docker info | grep -i userland`로 헤어핀 이슈 우회 확인 (스모크 테스트)

이후 사람이 할 일은 커밋 하나 push해서 backend-build → backend-deploy 파이프라인이 실제로 도는지 확인하는 것뿐이다.

전제 조건: 로컬에 `tailscale`, `jq`, `gh`(로그인된 상태) CLI가 설치돼 있어야 하고, `deploy/gitlab/.env`가 `.env.example`을 기반으로 미리 채워져 있어야 한다(GITHUB_PAT, EXTERNAL_DB_* 등).

## 삭제

검증이 끝나면 NAT Gateway 과금을 막기 위해 통째로 내린다.

```bash
terraform destroy
```

ECR 리포지토리는 이 스택에 없으니(`terraform/cloud-infra` 참고) destroy해도 이미지는 그대로 남는다.
