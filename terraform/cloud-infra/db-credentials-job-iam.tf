# backend-db-credentials(Secret)의 DB_USERNAME/DB_PASSWORD를 RDS Secrets Manager에서
# 가져와 채우는 역할. 예전엔 Terraform이 kubernetes_manifest로 ExternalSecret을 직접
# 만들었는데 두 가지 문제가 있었다:
#   1. plan 단계에서 실제 클러스터에 붙어 스키마를 확인해야 해서, 클러스터가 같은
#      apply 안에서 만들어지는 "완전히 새로 생성"하는 경우 "no client config"로 실패.
#   2. destroy 때도 Terraform이 그 객체가 실제로 지워질 때까지 기다리는데, ESO
#      컨트롤러가 EKS 노드 그룹과 병렬로 먼저 사라지면 finalizer를 아무도 못 지워 멈춤.
# 둘 다 Terraform이 "클러스터 안의 리소스"를 직접 소유해서 생기는 문제라, 여기서는
# IAM 역할만 만들고 실제 Secret 생성은 deploy 레포의 ArgoCD PreSync Hook Job
# (k8s/backend/overlays/cloud/db-credentials-job.yaml — schema-apply와 같은 패턴)으로
# 옮긴다. 그 Job이 런타임에 RDS를 describe해서 Secrets Manager ARN을 알아내고 값을
# 가져온다 — ARN 자체는 git에 못 올리지만 "어떻게 찾는지" 로직은 코드로 커밋해도 된다.
# IAM 정책의 Resource는 Terraform이 이미 아는 정확한 ARN으로 좁힌다(와일드카드 불필요).
#
# 인증은 IRSA(OIDC 연합) 대신 EKS Pod Identity를 쓴다 — IRSA는 ServiceAccount의
# eks.amazonaws.com/role-arn 애노테이션에 이 역할의 전체 ARN(계정 ID 포함)을 평문으로
# 적어야 해서, deploy 레포(git)에 계정 ID가 그대로 노출된다. Pod Identity는 그 연결을
# Terraform의 aws_eks_pod_identity_association이 AWS 쪽에서 직접 등록해서, 매니페스트엔
# ServiceAccount 이름만 있으면 되고 ARN은 git에 전혀 안 남는다. 신뢰 정책도 OIDC
# federation 조건 없이 AWS가 정한 고정 형식(Service: pods.eks.amazonaws.com)이면
# 된다 — "어떤 ServiceAccount가 쓸 수 있는지"는 신뢰 정책이 아니라 association
# 리소스 쪽에서 결정된다.
resource "aws_iam_role" "db_credentials_job" {
  name = "${var.name_prefix}-db-credentials-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "db_credentials_job" {
  name = "${var.name_prefix}-db-credentials-job-policy"
  role = aws_iam_role.db_credentials_job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "rds:DescribeDBInstances"
        Resource = aws_db_instance.this.arn
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_db_instance.this.master_user_secret[0].secret_arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Pod Identity Agent는 DaemonSet이라 노드가 있어야 스케줄된다 — depends_on으로 노드
# 그룹 뒤에 두지만, 이 애드온/association 자체는 kubernetes_manifest와 달리 클러스터
# 안의 실제 객체(ServiceAccount 등)를 몰라도 되는 순수 AWS API 리소스라 체이닝 문제가
# 없다 — backend-cdn.tf처럼 변수 게이트+2단계 apply가 필요 없이 첫 apply에 바로 포함된다.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [aws_eks_node_group.this]
}

# ServiceAccount 이름만으로 미리 연결해둔다 — 그 ServiceAccount가 나중에(ArgoCD가)
# 생기기 전이어도 상관없다.
resource "aws_eks_pod_identity_association" "db_credentials_job" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "rush-coupon"
  service_account = "db-credentials-job"
  role_arn        = aws_iam_role.db_credentials_job.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}
