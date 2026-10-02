output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "eks_oidc_provider_arn" {
  description = "#56/#57에서 IRSA 역할 신뢰정책에 쓸 OIDC Provider ARN"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "eks_cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "#56 ALB가 사용할 퍼블릭 서브넷"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "rds_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "rds_master_user_secret_arn" {
  description = "RDS가 자동 생성한 Secrets Manager 시크릿 ARN (#57 ESO가 참조할 대상)"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "elasticache_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "mq_console_url" {
  value = aws_mq_broker.this.instances[0].console_url
}

output "mq_amqp_endpoint" {
  description = "AMQPS(5671) 엔드포인트 — endpoints 배열 순서가 안 보장돼서 scheme으로 직접 골라낸다 (console_url이 [0]으로 나온 적 있음)"
  value       = [for e in aws_mq_broker.this.instances[0].endpoints : e if startswith(e, "amqps://")][0]
}

output "mq_username" {
  value = var.mq_username
}

output "mq_password" {
  value     = random_password.mq.result
  sensitive = true
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "eso_role_arn" {
  description = "install-eso.sh가 ServiceAccount annotation으로 쓸 IRSA 역할 ARN"
  value       = aws_iam_role.eso.arn
}

output "alb_controller_role_arn" {
  description = "install-alb-controller.sh가 ServiceAccount annotation으로 쓸 IRSA 역할 ARN"
  value       = aws_iam_role.alb_controller.arn
}

output "db_credentials_job_role_arn" {
  description = "db-credentials-job Job이 쓰는 IAM 역할 ARN — EKS Pod Identity(aws_eks_pod_identity_association)로 연결돼 있어 매니페스트 어디에도 안 적는다. 디버깅/조회용 참고 출력"
  value       = aws_iam_role.db_credentials_job.arn
}

output "frontend_bucket_name" {
  description = "#59 frontend-deploy-cloud CI job이 aws s3 sync 대상으로 쓸 버킷 이름"
  value       = aws_s3_bucket.frontend.bucket
}

output "frontend_cloudfront_distribution_id" {
  description = "#59 frontend-deploy-cloud CI job이 캐시 무효화에 쓸 CloudFront 배포 ID"
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_url" {
  value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "backend_cdn_url" {
  description = "VITE_API_BASE_URL_CLOUD로 써야 할 값 — enable_backend_cdn=true일 때만 값이 있다"
  value       = var.enable_backend_cdn ? "https://${aws_cloudfront_distribution.backend[0].domain_name}" : null
}
