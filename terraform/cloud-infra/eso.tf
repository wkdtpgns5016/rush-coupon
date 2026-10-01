# External Secrets Operator(ESO)가 동기화해올 값들. DB_USERNAME/DB_PASSWORD는 여기 없다 —
# #55에서 RDS가 manage_master_user_password로 이미 Secrets Manager에 만들어둔 비밀을
# 그대로 읽어 쓴다(새로 안 만듦). 나머지 "대부분 설정값"만 Parameter Store(SecureString).

locals {
  ssm_prefix = "/${var.name_prefix}"
}

# #59(S3+CloudFront)가 끝나야 실제 값을 안다. 그때 var.cors_origin만 갱신하고
# terraform apply하면 ESO가 자동으로 재동기화한다(기본 refreshInterval 1h).
resource "aws_ssm_parameter" "cors_origin" {
  name  = "${local.ssm_prefix}/CORS_ORIGIN"
  type  = "SecureString"
  value = var.cors_origin
}

resource "aws_ssm_parameter" "valkey_host" {
  name  = "${local.ssm_prefix}/VALKEY_HOST"
  type  = "SecureString"
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

resource "aws_ssm_parameter" "valkey_port" {
  name  = "${local.ssm_prefix}/VALKEY_PORT"
  type  = "SecureString"
  value = "6379"
}

resource "aws_ssm_parameter" "rabbitmq_host" {
  name = "${local.ssm_prefix}/RABBITMQ_HOST"
  type = "SecureString"
  # 앱 코드(rabbitmq.module.ts)가 `${protocol}://${host}:${port}/...`로 직접 조립하므로
  # 여기엔 순수 호스트명만 넣어야 한다 — amqps:// 스킴과 :5671 포트를 벗겨낸다.
  value = split(":", replace([for e in aws_mq_broker.this.instances[0].endpoints : e if startswith(e, "amqps://")][0], "amqps://", ""))[0]
}

resource "aws_ssm_parameter" "rabbitmq_port" {
  name  = "${local.ssm_prefix}/RABBITMQ_PORT"
  type  = "SecureString"
  value = "5671"
}

resource "aws_ssm_parameter" "rabbitmq_username" {
  name  = "${local.ssm_prefix}/RABBITMQ_USERNAME"
  type  = "SecureString"
  value = var.mq_username
}

resource "aws_ssm_parameter" "rabbitmq_password" {
  name  = "${local.ssm_prefix}/RABBITMQ_PASSWORD"
  type  = "SecureString"
  value = random_password.mq.result
}

resource "aws_ssm_parameter" "db_host" {
  name  = "${local.ssm_prefix}/DB_HOST"
  type  = "SecureString"
  value = aws_db_instance.this.address
}

resource "aws_ssm_parameter" "db_port" {
  name  = "${local.ssm_prefix}/DB_PORT"
  type  = "SecureString"
  value = tostring(aws_db_instance.this.port)
}

resource "aws_ssm_parameter" "db_database" {
  name  = "${local.ssm_prefix}/DB_DATABASE"
  type  = "SecureString"
  value = var.rds_db_name
}

# --- ESO용 IRSA 역할 ---
resource "aws_iam_role" "eso" {
  name = "${var.name_prefix}-eso-role"

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
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# 이 경로(/${name_prefix}/*) 아래 파라미터와, RDS가 만든 그 Secrets Manager 비밀 하나만
# 읽을 수 있게 좁힌다 — #54 tailscale authkey 때와 같은 최소 권한 원칙.
resource "aws_iam_role_policy" "eso" {
  name = "${var.name_prefix}-eso-policy"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.region}:*:parameter${local.ssm_prefix}/*"
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
            "kms:ViaService" = ["ssm.${var.region}.amazonaws.com", "secretsmanager.${var.region}.amazonaws.com"]
          }
        }
      }
    ]
  })
}
