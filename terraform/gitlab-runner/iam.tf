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
