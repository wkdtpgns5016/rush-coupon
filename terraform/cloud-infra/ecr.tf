# 원래 #54(terraform/gitlab-runner)에 있었는데, 그 스택이 자주 스핀업/destroy되는
# 일회성 CI 검증용이라 ECR까지 같이 사라지는 문제가 있어서 여기(EKS가 있는 영구적인
# 스택)로 옮겼다. gitlab-runner의 EC2 IAM 역할(AmazonEC2ContainerRegistryPowerUser)은
# 계정 전체 권한이라 이 리소스가 어느 스택에 있든 push에는 영향이 없다.
resource "aws_ecr_repository" "backend" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.name_prefix}-ecr"
  }
}

# 태그 없는 이미지(빌드 실패/중간 산출물)가 쌓이는 것만 정리 — 실제 배포 태그는 건드리지 않음
resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images older than 3 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}
