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
  value = aws_mq_broker.this.instances[0].endpoints[0]
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
