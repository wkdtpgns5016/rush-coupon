resource "aws_iam_role" "gitlab_runner" {
  name = "${var.name_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.name_prefix}-role"
  }
}

# backend-build 잡이 docker push로 ECR에 이미지를 올릴 수 있도록 부여
resource "aws_iam_role_policy_attachment" "ecr_push" {
  role       = aws_iam_role.gitlab_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_instance_profile" "gitlab_runner" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.gitlab_runner.name
}

# 부팅 시 tailscale authkey를 SSM Parameter Store에서 가져오기 위한 권한.
# 이 파라미터 하나로만 범위를 좁힌다 — 다른 시크릿은 애초에 이 계정 EC2 역할이 몰라도 된다.
# #59 frontend-deploy-cloud 잡이 S3 sync + CloudFront invalidation을 할 수 있게 부여.
# S3는 버킷 ARN으로 좁히지만(cloud-infra의 버킷 이름 규칙과 같은 값을 여기서도 계산 —
# 두 스택이 별도 state라 리소스 참조 대신 같은 규칙을 복제), CloudFront invalidation은
# 배포 ID가 cloud-infra apply 전엔 알 수 없는 AWS 생성 값이라 리소스를 좁힐 수 없다.
# 다만 invalidation은 캐시만 비우는 동작이라(데이터 노출/변조 없음, 비용도 상한 있음)
# Resource "*"로 둬도 블라스트 반경이 작다고 판단했다.
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "frontend_deploy" {
  name = "${var.name_prefix}-frontend-deploy"
  role = aws_iam_role.gitlab_runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.cloud_infra_name_prefix}-frontend-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::${var.cloud_infra_name_prefix}-frontend-${data.aws_caller_identity.current.account_id}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ssm_tailscale_authkey" {
  name = "${var.name_prefix}-ssm-authkey"
  role = aws_iam_role.gitlab_runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.tailscale_authkey.arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}
