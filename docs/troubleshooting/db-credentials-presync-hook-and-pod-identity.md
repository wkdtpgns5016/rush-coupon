# [트러블슈팅] RDS 자격증명을 완전히 빈 클라우드 환경에서 부트스트랩할 때 겪은 문제 5가지

## 요약

| 항목 | 내용 |
|---|---|
| 배경 | M6 — RDS Secrets Manager의 DB_USERNAME/PASSWORD를 클러스터에 채워 넣는 작업. 처음엔 Terraform이 `kubernetes_manifest`로 ExternalSecret을 직접 만들었는데, "완전히 빈 환경에서 처음부터 전체 스택을 올린다"는 검증 시나리오에서만 드러나는 문제가 연쇄적으로 나왔다 |
| 이슈 1 | Terraform이 클러스터 내부 리소스를 직접 소유하면 생성·삭제 양쪽에서 체이닝 문제가 생긴다 |
| 이슈 2 | ArgoCD PreSync Hook Job이 의존하는 리소스(ServiceAccount, ConfigMap)에 PreSync 애노테이션을 빠뜨리면 "not found"로 깨진다 — 같은 실수를 두 번 반복 |
| 이슈 3 | PreSync Job은 일반 Sync 단계 리소스(ExternalSecret)의 결과를 원천적으로 볼 수 없다 — 기존 환경을 재사용할 땐 몰랐던 레이스 컨디션 |
| 이슈 4 | `schema-apply` 컨테이너 이미지의 psql·libc 호환성 삼중고(Amazon Linux 2 → SCRAM 미지원 → pgdg 리포 실패) |
| 이슈 5 | IRSA는 ServiceAccount 애노테이션에 AWS 계정 ID가 포함된 IAM 역할 ARN을 평문으로 git에 남긴다 |
| 관련 이슈 | M6 — 완전히 빈 환경에서 `terraform apply && install-all.sh`를 처음부터 재검증하는 과정에서 전부 발견 |

---

## 배경

RDS는 `manage_master_user_password`로 비밀번호를 AWS가 Secrets Manager에 자동 생성/관리하게 해뒀다(`terraform/cloud-infra/rds.tf`). 이 값을 클러스터 안의 `backend-db-credentials` Secret에 채워 넣어야 백엔드가 DB에 붙을 수 있는데, 이 메커니즘을 어디에 둘지가 이번 문제들의 공통 원인이다.

## 이슈 1. Terraform이 클러스터 내부 리소스를 직접 소유하면 생성·삭제 양쪽에서 체이닝 문제가 생긴다

### 증상

`terraform apply`로 EKS 클러스터와 ExternalSecret(`kubernetes_manifest`)을 같은 apply 안에서 같이 만들면:
```
Error: cannot create REST client: no client config
```
destroy 시에는 ESO 컨트롤러(EKS 노드 그룹 위에서 돎)가 노드 그룹과 병렬로 먼저 사라지면, ExternalSecret의 finalizer를 아무도 지우지 못해 `terraform destroy`가 영원히 멈췄다.

### 원인

`kubernetes_manifest`는 `plan` 단계에서 실제 클러스터에 붙어 대상 리소스의 스키마를 확인해야 하는데, 클러스터 자체가 같은 apply로 처음 생기는 경우 그 시점엔 아직 연결할 클러스터가 없다. destroy는 반대로 Terraform이 "그 객체가 실제로 지워질 때까지" 기다리는데, 그 삭제를 수행하는 컨트롤러(ESO)가 노드 그룹 삭제와 경쟁하다 먼저 죽어버리면 아무도 마무리를 못 한다. 두 문제 모두 "Terraform이 클러스터 안의 리소스를 직접 소유"해서 생긴다.

### 해결

Terraform은 IAM 역할까지만 만들고, 실제 Secret 생성은 **ArgoCD PreSync Hook Job**(`db-credentials-job.yaml`)으로 옮겼다. 이 Job이 런타임에 RDS를 `describe-db-instances`로 조회해 Secrets Manager ARN을 알아내고, 그 값을 가져와 `backend-db-credentials` Secret에 채운다. ARN 자체는 git에 못 올리는 값이지만, "어떻게 그 값을 찾아내는지" 로직은 코드로 커밋해도 안전하다 — IAM 정책이 이 역할을 그 ARN 하나로만 이미 좁혀뒀기 때문이다.

```hcl
# terraform/cloud-infra/db-credentials-job-iam.tf — IAM 역할만 Terraform이 만든다
resource "aws_iam_role_policy" "db_credentials_job" {
  policy = jsonencode({
    Statement = [
      { Action = "rds:DescribeDBInstances", Resource = aws_db_instance.this.arn },
      { Action = "secretsmanager:GetSecretValue", Resource = aws_db_instance.this.master_user_secret[0].secret_arn },
    ]
  })
}
```

### 교훈

클러스터가 아직 없을 수도 있는 시점(최초 apply)과 컨트롤러가 먼저 사라질 수도 있는 시점(destroy)을 모두 안전하게 다루려면, "클러스터 안의 리소스"는 애초에 Terraform이 아니라 그 클러스터를 실제로 관리하는 도구(ArgoCD)가 만들게 하는 게 맞다. Terraform은 그 리소스가 필요로 하는 **AWS 쪽 권한**까지만 책임진다.

---

## 이슈 2. PreSync Job이 의존하는 리소스도 전부 PreSync여야 한다 — 같은 실수를 두 번 반복

### 증상 1 — ServiceAccount

```
Error creating: pods "db-credentials-apply-xxxxx" is forbidden: error looking up service account rush-coupon/db-credentials-job: serviceaccount "db-credentials-job" not found
```

### 증상 2 — ConfigMap

`schema-apply` Job이 `/sql/schema.sql`을 마운트하지 못해 `CreateContainerConfigError`로 멈췄다.

### 원인

ArgoCD의 동기화 단계는 `PreSync` → `Sync` → `PostSync` 순서로 엄격히 분리된다. `db-credentials-apply`/`schema-apply` Job은 둘 다 `PreSync` hook인데, 정작 그 Job이 쓰는 `ServiceAccount`/`Role`/`RoleBinding`이나 `schema-sql` ConfigMap에는 `PreSync` 애노테이션을 깜빡해서, 이 리소스들이 Job보다 **항상 늦은** 일반 `Sync` 단계에서야 생성됐다. "PreSync Job이 참조하는 건 전부 PreSync여야 한다"는 규칙을 처음엔 Job 본체에만 적용하고, 그 Job이 간접적으로 필요로 하는 주변 리소스에는 적용을 깜빡한 것 — 완전히 같은 실수를 ServiceAccount 1회, ConfigMap 1회 반복했다.

### 해결

둘 다 `argocd.argoproj.io/hook: PreSync` 추가. ServiceAccount/Role/RoleBinding에는 `hook-delete-policy`를 넣지 않는다 — Job처럼 "한 번 성공하면 끝"이 아니라 매 sync마다 계속 참조되는 리소스라 남아있어야 하기 때문이다.

### 교훈

ArgoCD PreSync Hook을 쓸 때는 Job 자체뿐 아니라 **그 Job이 마운트/참조하는 모든 것**(ServiceAccount, ConfigMap, Secret 등)의 hook 단계까지 전부 점검해야 한다. 기존에 남아있던 클러스터로 테스트하면 이런 리소스가 이미 존재해서 순서 문제가 전혀 드러나지 않는다 — "완전히 빈 환경에서부터" 검증해야만 잡히는 종류의 버그다.

---

## 이슈 3. PreSync Job은 일반 Sync 단계 리소스의 결과를 원천적으로 볼 수 없다

### 증상

완전히 빈 환경에서 최초 sync를 돌리면 `schema-apply`가 `CreateContainerConfigError`로 멈췄다. 기존 환경을 재사용한 테스트에서는 한 번도 재현되지 않았던 문제다.

### 원인

`schema-apply`는 DB_HOST/PORT/DATABASE/SSL 값을 `backend-db-credentials-connection`(ExternalSecret)의 `secretKeyRef`로 참조하고 있었다. 그런데 ExternalSecret은 일반 `Sync` 단계 리소스이고, `schema-apply`는 `PreSync` 단계다. ArgoCD의 단계 구분상 **PreSync는 Sync보다 항상 먼저 끝나므로, PreSync Job은 그 어떤 sync-wave를 쓰더라도 non-hook 리소스의 결과를 볼 수 없다** — 이슈 2(둘 다 PreSync인데 순서만 틀린 경우)와 달리 이번엔 아예 다른 단계에 속한 리소스라 순서를 맞추는 걸로는 해결이 안 된다. 기존 테스트에서 안 드러난 이유는 이전 sync에서 이미 채워진 Secret 값이 남아있는 클러스터를 계속 재사용했기 때문이다.

### 해결 — 그리고 검토했지만 보류한 대안

"정석" 대안은 ArgoCD에 ExternalSecret용 커스텀 헬스 체크를 등록하고 적절한 sync-wave를 매겨 순서를 보장하는 것이다. 이게 일반적인 경우엔 맞는 방향이지만, 클러스터 전역 설정을 바꿔야 하고 검증 리스크도 있어서 이번엔 **더 단순한 방법**을 택했다 — `schema-apply`도 `db-credentials-job`과 같은 IAM 역할(Pod Identity)로 RDS를 직접 describe해서 연결 정보를 얻도록 바꿨다. ExternalSecret에 전혀 의존하지 않게 되어 레이스 컨디션 자체가 사라진다.

```yaml
# ExternalSecret의 secretKeyRef 대신, 같은 Pod Identity 역할로 RDS를 직접 조회
env:
  - name: DB_INSTANCE_ID
    value: rush-coupon-cloud-postgres
command: ["sh", "-c", "DB_INFO=$(aws rds describe-db-instances ...) ..."]
```

일반 애플리케이션 시크릿까지 전부 이 방식으로 바꿀 필요는 없다 — 이건 "배포 과정에서 반드시 먼저 끝나야 하는 게이트 Job"에만 해당하는 예외적 조치이고, ExternalSecret+커스텀 헬스체크 방식은 차기 개선 과제로 남겨뒀다.

### 교훈

ArgoCD의 hook 단계는 "먼저 실행되길 바라는 순서"가 아니라 "완전히 분리된 두 단계"로 이해해야 한다. PreSync 쪽에 있는 Job은 sync-wave를 아무리 조정해도 non-hook 리소스를 볼 수 없다 — 둘 중 하나를 같은 단계로 옮기거나(이슈 2처럼), 아예 그 리소스에 대한 의존을 없애야(이번 경우) 한다.

---

## 이슈 4. `schema-apply` 이미지의 psql·libc 호환성 삼중고

### 증상 1 — 패키지 이름

`amazon/aws-cli:2.17.62`(Amazon Linux 2 베이스)에서 `yum install postgresql15`를 했더니:
```
psql: command not found
```

### 증상 2 — SCRAM 미지원

패키지 이름을 `postgresql`로 고치고 나니 설치는 됐지만:
```
psql: error: SCRAM authentication requires libpq version 10 or above
```

### 원인

AL2의 `postgresql` yum 패키지는 버전 9.2로, RDS가 요구하는 SCRAM-SHA-256 인증을 지원하지 않는다. pgdg(PostgreSQL 공식) 저장소로 최신 버전을 받으려 해도, AL2에서는 `$releasever`가 "2"로 해석돼 EL7용 저장소 메타데이터 URL이 404로 깨진다.

### 해결

이미지를 `debian:12-slim`으로 바꾸고 `apt-get install postgresql-client`(v15, SCRAM 지원)와 AWS CLI v2 공식 zip 설치 스크립트를 조합했다. Alpine(`postgres:16-alpine` + musl)도 검토했으나, AWS CLI v2는 musl과 근본적으로 호환되지 않고(별도 트러블슈팅: [gitlab-runner-aws-migration-registry-issues.md](gitlab-runner-aws-migration-registry-issues.md) 이슈 2) v1(Python, pip)은 유지보수 모드라 장기적으로 피하는 게 맞다고 판단해 Debian + AWS CLI v2 조합으로 정착했다.

### 교훈

"RDS용 psql 클라이언트가 필요하다"는 요구사항은 단순해 보여도, 베이스 이미지의 libc(musl/glibc)와 패키지 매니저 저장소 버전 해석 방식에 따라 전혀 다른 실패 양상으로 나타난다. Debian/Ubuntu 계열처럼 두 조건(최신 psql, glibc) 모두를 기본 저장소에서 만족하는 베이스를 고르는 게 가장 단순하다.

---

## 이슈 5. IRSA는 ServiceAccount 애노테이션에 AWS 계정 ID가 포함된 ARN을 평문으로 git에 남긴다

### 배경

`db-credentials-job`의 AWS 인증은 원래 IRSA(IAM Roles for Service Accounts)를 썼다. IRSA는 OIDC federation 방식이라, ServiceAccount에 `eks.amazonaws.com/role-arn: arn:aws:iam::<계정ID>:role/...` 애노테이션을 직접 적어야 한다. 이 매니페스트는 deploy 레포(git)에 커밋되는 파일이라, **AWS 계정 ID가 그대로 git 히스토리에 평문으로 남는다**는 문제가 있었다.

### 해결

**EKS Pod Identity**로 전환했다. Terraform이 `aws_eks_addon`(eks-pod-identity-agent)과 `aws_eks_pod_identity_association`을 만들어서, "네임스페이스 + ServiceAccount 이름"만으로 AWS 쪽에서 미리 역할을 연결해둔다.

```hcl
resource "aws_eks_pod_identity_association" "db_credentials_job" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "rush-coupon"
  service_account = "db-credentials-job"
  role_arn        = aws_iam_role.db_credentials_job.arn
}
```

신뢰 정책도 OIDC federation 조건 없이 AWS가 정한 고정 형식(`Principal.Service = pods.eks.amazonaws.com`)이면 된다 — "어떤 ServiceAccount가 이 역할을 쓸 수 있는지"는 신뢰 정책이 아니라 association 리소스 쪽에서 결정되기 때문이다. 그 결과 `db-credentials-job.yaml`의 ServiceAccount에는 이름 외에 아무 애노테이션도 필요 없어졌고, 계정 ID는 Terraform state(gitignore 대상)에만 남는다.

association 리소스는 `kubernetes_manifest`와 달리 클러스터 안의 실제 객체(ServiceAccount)를 몰라도 되는 순수 AWS API 리소스라, 이슈 1과 같은 체이닝 문제도 없다 — ServiceAccount가 나중에(ArgoCD가) 생기기 전에 먼저 등록해둬도 상관없다.

### 교훈

같은 "ServiceAccount에 AWS 권한을 주는" 목적이라도, IRSA는 "누가 쓸 수 있는지"를 매니페스트(git)에 적어야 하고 Pod Identity는 그 결정을 AWS 쪽 리소스로 옮긴다. git에 커밋되는 파일에 계정 식별자가 들어가는 걸 피하고 싶다면 Pod Identity 쪽이 구조적으로 더 안전하다.

## 관련 파일
- [terraform/cloud-infra/db-credentials-job-iam.tf](../../terraform/cloud-infra/db-credentials-job-iam.tf) — 이슈 1, 5의 IAM 역할 + Pod Identity 연결
- [k8s/backend/overlays/cloud/db-credentials-job.yaml](https://github.com/wkdtpgns5016/rush-coupon-deploy/blob/main/k8s/backend/overlays/cloud/db-credentials-job.yaml) — 이슈 1, 2, 5가 반영된 PreSync Hook Job
- [k8s/backend/overlays/cloud/schema-apply-job.yaml](https://github.com/wkdtpgns5016/rush-coupon-deploy/blob/main/k8s/backend/overlays/cloud/schema-apply-job.yaml) — 이슈 2, 3, 4가 반영된 PreSync Hook Job
- [k8s/backend/argocd-application-cloud.yaml](https://github.com/wkdtpgns5016/rush-coupon-deploy/blob/main/k8s/backend/argocd-application-cloud.yaml) — `CreateNamespace=true` (같은 검증 과정에서 함께 발견된 네임스페이스 부재 문제)
- [m6-cloud-load-test-report.md](../load-test/m6-cloud-load-test-report.md) — 이 전환이 나온 배경(M6 클라우드 마이그레이션) 요약
