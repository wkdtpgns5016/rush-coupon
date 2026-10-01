resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

# 비밀번호를 변수로 안 받고 RDS 자체 기능(manage_master_user_password)으로 맡긴다.
# RDS가 Secrets Manager에 랜덤 비밀번호를 생성해서 저장/관리 — plaintext가 Terraform
# state/변수 어디에도 안 남는다. 지난 세션에 정한 "Secrets Manager는 DB 자격증명
# 로테이션 시연용"이라는 계획을 이 시점에 자연스럽게 시작하는 셈이다 (#57에서
# External Secrets Operator가 이 Secrets Manager 시크릿을 그대로 참조하면 됨).
resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-postgres"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage
  storage_type          = "gp3"
  max_allocated_storage = 0 # 자동 스토리지 확장 비활성화 — 비용 예측 가능하게

  db_name  = var.rds_db_name
  username = var.rds_username

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                = false # 비용 때문에 단일 AZ (M6은 짧은 검증용, HA 시연 대상 아님)
  backup_retention_period = 0     # 짧게 쓰고 destroy할 거라 자동 백업 비활성화
  skip_final_snapshot     = true  # destroy 시 최종 스냅샷 안 만듦 (스냅샷은 destroy 후에도 과금됨)
  deletion_protection     = false

  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}
