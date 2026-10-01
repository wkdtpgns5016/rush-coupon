resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-cache-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

# Valkey는 레거시 aws_elasticache_cluster(CreateCacheCluster API)를 지원 안 하고
# Replication Group API로만 생성 가능하다 (AWS 쪽 제약). num_cache_clusters=1 +
# automatic_failover_enabled=false로 사실상 단일 노드로 구성 — HA 시연이 목적이 아니라
# 매니지드 서비스 자체 검증이 목적이라 복제 없이 최소 구성으로 간다.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-valkey"
  description          = "rush-coupon valkey - single node for M6 verification" # ElastiCache description은 비 ASCII를 non-printable로 취급해서 거부함 (#54 SG description과 같은 류의 제약)
  engine               = "valkey"
  engine_version       = var.elasticache_engine_version
  node_type            = var.elasticache_node_type
  num_cache_clusters   = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.elasticache.id]

  automatic_failover_enabled = false # num_cache_clusters=1일 땐 반드시 false
  apply_immediately          = true

  tags = {
    Name = "${var.name_prefix}-valkey"
  }
}
