# EKS가 자동 생성하는 클러스터 보안그룹(컨트롤플레인+노드가 공유) — 이걸 소스로 삼아
# RDS/ElastiCache/Amazon MQ 인그레스를 "이 클러스터에서 오는 트래픽만" 허용한다.
locals {
  eks_cluster_sg_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "RDS - allow Postgres from EKS cluster only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.eks_cluster_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}

resource "aws_security_group" "elasticache" {
  name        = "${var.name_prefix}-elasticache-sg"
  description = "ElastiCache - allow Valkey from EKS cluster only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [local.eks_cluster_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-elasticache-sg"
  }
}

resource "aws_security_group" "mq" {
  name        = "${var.name_prefix}-mq-sg"
  description = "Amazon MQ - allow RabbitMQ(AMQPS/HTTPS console) from EKS cluster only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 5671
    to_port         = 5671
    protocol        = "tcp"
    security_groups = [local.eks_cluster_sg_id]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [local.eks_cluster_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-mq-sg"
  }
}
