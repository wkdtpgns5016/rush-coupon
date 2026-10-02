# 클라우드 환경 세팅 가이드 (M6)

온프레미스 환경([fresh-environment-setup.md](fresh-environment-setup.md))이 이미 떠 있다는 전제 하에, 같은 아키텍처(Valkey+RabbitMQ)를 AWS 관리형 서비스(EKS+RDS+ElastiCache+Amazon MQ)로 재현하는 절차다. 상시 운영이 아니라 "스핀업 → 부하테스트 → destroy"를 전제로 한다.

서로 다른 VPC를 쓰는 독립된 Terraform 스택 두 개로 구성되고, 동시에 떠 있을 필요는 없다.

## 전제 조건

- AWS CLI 프로파일(`--profile rush-coupon-admin` 등)과 적절한 IAM 권한
- 로컬에 `terraform`, `aws-cli`, `kubectl`, `tailscale`, `jq`, `gh`(로그인된 상태) 설치
- `deploy/gitlab/.env`가 `.env.example` 기반으로 미리 채워져 있음 (`GITHUB_PAT`, `EXTERNAL_DB_*` 등 — 1번 스크립트가 그대로 재사용)

## 1. GitLab+Runner를 AWS로 (온프레미스 클러스터 대상으로 먼저 검증)

아직 EKS가 없어도 시작할 수 있다. ArgoCD가 보는 건 GitLab이 아니라 GitHub `deploy` 브랜치라서, "GitLab이 AWS에 있어도 CI/CD가 되는가"를 새 EKS 스택과 분리해서 먼저 검증한다.

```bash
cd terraform/gitlab-runner
cp terraform.tfvars.example terraform.tfvars   # ssh_public_key, tailscale_authkey 채우기
terraform init
terraform apply && ./bootstrap-and-verify.sh
```

`bootstrap-and-verify.sh`가 Tailscale 조인 대기 → `deploy/gitlab/.env` 갱신 → GitLab+Runner 부트스트랩(기존 `deploy/gitlab/` 스크립트 재사용) → CI/CD Variables 등록 → GitHub Secrets/Variables 자동 갱신 → 헤어핀 스모크 테스트까지 전부 처리한다. 자세한 내부 동작과 설계 결정은 [terraform/gitlab-runner/README.md](../../terraform/gitlab-runner/README.md) 참고.

끝나면 커밋 하나 push해서 `backend-build` → `backend-deploy` 파이프라인이 실제로 온프레미스 클러스터에 배포되는지 확인한다.

## 2. EKS/RDS/ElastiCache/Amazon MQ 프로비저닝 및 배포

```bash
cd terraform/cloud-infra
terraform init
terraform apply
./install-all.sh          # ESO/ALB Controller/metrics-server/모니터링/ArgoCD — 순서가 중요해서 스크립트가 강제함
./bootstrap-backend-app.sh  # ArgoCD Application 적용 — 여기서 실제로 backend/worker가 배포됨
```

EKS 클러스터 생성은 10~15분, 노드그룹까지 합치면 15~20분 정도 걸린다. `install-all.sh`는 애드온만 설치하고, 실제 애플리케이션 배포는 `bootstrap-backend-app.sh`가 별도로 한다(ArgoCD Application을 deploy 브랜치에서 적용). 설계 결정(온프레미스와 동일 스펙 노드, RDS 비밀번호 자동 관리 등)과 kubeconfig 연결/비밀번호 확인 명령은 [terraform/cloud-infra/README.md](../../terraform/cloud-infra/README.md) 참고.

## 3. 부하 테스트

```bash
k6/scripts/run-cloud.sh <baseline|spike|scaleout>
```

k6는 로컬에서 CloudFront 엔드포인트로 직접 실행하고, RDS 의존 후처리(배출 대기·정합성 검증·정리)는 RDS가 private subnet이라 로컬에서 직접 접속할 수 없어 EKS 안의 일회성 Pod에서 자동으로 수행된다.

## 4. 삭제

**`cloud-infra`에서 `terraform destroy`를 바로 실행하면 안 된다.** ALB Controller가 Ingress를 보고 만든 ALB는 Terraform이 모르는 리소스라서, 먼저 정리하지 않으면 VPC/서브넷 삭제가 막히거나 ALB가 고아로 남아 계속 과금될 수 있다.

```bash
cd terraform/cloud-infra && ./teardown.sh   # ArgoCD Application 삭제 → Ingress 삭제 → ALB 소멸 대기 → terraform destroy
cd terraform/gitlab-runner && terraform destroy
```

`gitlab-runner` 쪽 ECR 리포지토리는 `cloud-infra`에 있으므로(스택이 자주 스핀업/destroy되는 쪽에 두면 이미지가 같이 사라지는 문제가 있었음), `gitlab-runner`를 destroy해도 이미지는 그대로 남는다.
