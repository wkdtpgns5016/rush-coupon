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
resource "aws_iam_role" "db_credentials_job" {
  name = "${var.name_prefix}-db-credentials-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:rush-coupon:db-credentials-job"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
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
