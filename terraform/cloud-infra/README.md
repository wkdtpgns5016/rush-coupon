# cloud-infra (M6 #55)

EKS + RDS(PostgreSQL) + ElastiCache(Valkey) + Amazon MQ(RabbitMQ)를 Terraform으로 프로비저닝하는 스택이다. 목적은 "온프레미스에서 직접 운영하던 인프라를 AWS 매니지드 서비스로 바꾸면 뭐가 달라지는가"를 #60에서 측정하기 위한 기반을 마련하는 것 — 상시 운영이 아니라 스핀업 → #56/#57 적용 → #60 부하테스트 → destroy 흐름을 전제로 한다.

#54(gitlab-runner)와 완전히 별개 VPC(`10.70.0.0/16`)다. 두 스택이 동시에 떠 있을 필요가 없어서 네트워크를 공유하지 않는다.

## 설계 결정

- **EKS 노드그룹을 온프레미스 `k8s-worker`와 동일 스펙(4vCPU/8GB → `c5.xlarge`)으로 맞췄다.** t3(버스터블) 대신 c5(고정 성능)를 쓴 이유는, 부하테스트 중간에 CPU 크레딧이 바닥나서 성능이 떨어지는 현상이 "클라우드가 느리다"로 오인될 수 있어서다. 컴퓨트 스펙을 변수에서 빼야 #60 비교가 "매니지드냐 아니냐"의 순수한 효과를 보여준다.
- **노드 1대 고정, autoscaling 없음** — 온프레미스도 worker VM이 1대뿐이라 맞췄다.
- **RDS는 Aurora가 아니라 일반 PostgreSQL** — Aurora는 스토리지 아키텍처 자체가 다르고(3-AZ 분산 로그 구조), I/O 과금이라 비용 예측이 어렵다. 엔진/아키텍처를 거의 그대로 두고 "운영만 AWS가 가져간" 비교를 하려면 일반 RDS가 더 적합하다.
- **RDS 비밀번호는 `manage_master_user_password`로 RDS가 Secrets Manager에 자동 생성/관리** — 별도 변수 없이, 지난 세션에 정한 "Secrets Manager는 DB 자격증명 로테이션 시연용"이라는 계획을 자연스럽게 시작한다. `rds_master_user_secret_arn` 출력이 #57 External Secrets Operator가 참조할 대상이다.
- **ElastiCache/Amazon MQ는 단일 노드/SINGLE_INSTANCE** — HA 시연이 목적이 아니라 매니지드 서비스 자체의 검증이 목적이라 복제본 없이 최소 구성.
- **퍼블릭 서브넷을 2개 AZ에 만들어둔 이유는 지금(#55)이 아니라 #56** — ALB는 플랫폼 제약상 최소 2 AZ 서브넷이 필요해서 미리 만들어둔다. NAT Gateway 자체는 1개만 쓴다(비용).
- **IAM OIDC Provider**: #56(ALB Controller)/#57(External Secrets Operator)가 IRSA로 AWS 자격증명을 받기 위한 공용 전제 작업. `eks_oidc_provider_arn` 출력을 그때 참조한다.
- **EKS 노드 IAM 역할은 ECR `ReadOnly`** — #54의 EC2 역할(`PowerUser`, push까지 필요)과 다르게 노드는 pull만 하면 돼서 범위를 좁혔다.
- **ECR 리포지토리(`rush-coupon-backend`)가 원래 #54에 있었는데 여기로 옮겼다** — gitlab-runner는 검증할 때만 스핀업/destroy하는 스택이라, 거기 ECR을 두면 destroy할 때마다 EKS가 의존하는 레지스트리까지 같이 사라지는 문제가 실제로 발생했다. EKS가 있는 이 스택(상대적으로 수명이 긴 쪽)에 두는 게 맞다.

## 적용

```bash
cd terraform/cloud-infra
terraform init
terraform plan
terraform apply
```

필수 입력 변수가 없다 — RDS 비밀번호는 RDS가, Amazon MQ 비밀번호는 `random_password`가 자동 생성한다. 값을 바꾸고 싶을 때만 `terraform.tfvars.example`을 참고해서 `terraform.tfvars`를 만든다.

EKS 클러스터 생성은 보통 10~15분, 노드그룹까지 합치면 15~20분 정도 걸린다.

적용 후 kubectl 연결:
```bash
aws eks update-kubeconfig --name $(terraform output -raw eks_cluster_name) --region ap-northeast-2 --profile rush-coupon-admin
```

RDS 비밀번호 확인:
```bash
aws secretsmanager get-secret-value --secret-id $(terraform output -raw rds_master_user_secret_arn) --query SecretString --output text --profile rush-coupon-admin | jq .
```

Amazon MQ 비밀번호 확인:
```bash
terraform output -raw mq_password
```

## 삭제

**`terraform destroy`를 바로 실행하면 안 된다.** ALB Controller(#56)가 Ingress를 보고 만든 ALB는 Terraform이 전혀 모르는 리소스라서, 먼저 지우지 않으면 VPC/서브넷 삭제가 막히거나 ALB가 고아로 남아 계속 과금될 수 있다. 반드시 아래 순서로:

```bash
./teardown.sh
```

이 스크립트가 (1) Ingress 삭제 → (2) 그 VPC의 ALB가 실제로 사라질 때까지 폴링 → (3) `terraform destroy` 순서로 실행한다. ALB Controller 자체를 아직 안 올렸다면(Ingress가 없다면) 1~2단계는 자동으로 skip되고 바로 destroy로 넘어간다.

RDS는 `skip_final_snapshot = true`로 최종 스냅샷을 안 남기게 해뒀다(스냅샷은 destroy 후에도 과금 대상이라). Amazon MQ/EKS는 삭제에 몇 분 걸릴 수 있다.
