variable "region" {
  description = "리소스를 생성할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "사용할 AWS CLI profile (aws login으로 만든 dev-rush-coupon-admin 자격증명 브릿지)"
  type        = string
  default     = "rush-coupon-admin"
}

variable "name_prefix" {
  description = "생성되는 리소스 이름/태그 접두사"
  type        = string
  default     = "rush-coupon-cloud"
}

variable "azs" {
  description = "서브넷을 분산할 가용영역 2개 (EKS 컨트롤플레인/ALB는 최소 2 AZ 필요)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "vpc_cidr" {
  description = "이 스택 전용 VPC CIDR (#54 gitlab-runner VPC와 별개)"
  type        = string
  default     = "10.70.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "AZ별 퍼블릭 서브넷 CIDR — NAT Gateway(1개만 사용) + #56 ALB용"
  type        = list(string)
  default     = ["10.70.0.0/24", "10.70.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "AZ별 프라이빗 서브넷 CIDR — EKS 노드 + RDS/ElastiCache/Amazon MQ"
  type        = list(string)
  default     = ["10.70.10.0/24", "10.70.11.0/24"]
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

variable "eks_cluster_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.32"
}

variable "eks_node_instance_type" {
  description = "EKS 노드그룹 인스턴스 타입 (온프레미스 k8s-worker와 스펙 매칭: 4vCPU/8GB)"
  type        = string
  default     = "c5.xlarge"
}

variable "eks_node_desired_size" {
  description = "EKS 노드 개수 (온프레미스 k8s-worker가 1대라 고정 1대로 맞춤, autoscaling 없음)"
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

variable "rds_instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_engine_version" {
  description = "RDS PostgreSQL 엔진 버전 (기존 postgres:16-alpine과 메이저 버전 매칭)"
  type        = string
  default     = "16.15"
}

variable "rds_allocated_storage" {
  description = "RDS 스토리지 크기(GB)"
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "RDS 데이터베이스 이름 (기존 EXTERNAL_DB_NAME과 동일하게)"
  type        = string
  default     = "rush_coupon"
}

variable "rds_username" {
  description = "RDS 마스터 유저명 (기존 EXTERNAL_DB_USER와 동일하게). 비밀번호는 변수로 안 받고 RDS가 Secrets Manager에 자동 생성/관리(manage_master_user_password)"
  type        = string
  default     = "coupon_user"
}

# ---------------------------------------------------------------------------
# ElastiCache
# ---------------------------------------------------------------------------

variable "elasticache_node_type" {
  description = "ElastiCache 노드 타입"
  type        = string
  default     = "cache.t4g.micro"
}

variable "elasticache_engine_version" {
  description = "ElastiCache Valkey 엔진 버전 (기존 valkey/valkey:8-alpine과 메이저 버전 매칭)"
  type        = string
  default     = "8.2"
}

# ---------------------------------------------------------------------------
# Amazon MQ
# ---------------------------------------------------------------------------

variable "mq_instance_type" {
  description = "Amazon MQ 브로커 인스턴스 타입 (RabbitMQ 엔진은 t3 계열 자체를 지원 안 함 — describe-broker-instance-options 기준 m7g.medium이 가장 작고 저렴한 옵션, $0.1682/hr)"
  type        = string
  default     = "mq.m7g.medium"
}

variable "mq_engine_version" {
  description = "Amazon MQ RabbitMQ 엔진 버전 (기존 rabbitmq:4-alpine과 메이저 버전 매칭)"
  type        = string
  default     = "4.3"
}

variable "mq_username" {
  description = "Amazon MQ 유저명 (기존 RABBITMQ_DEFAULT_USER와 동일하게). 비밀번호는 random_password로 자동 생성"
  type        = string
  default     = "rush"
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

variable "ecr_repository_name" {
  description = "backend 이미지를 push할 ECR 리포지토리 이름 (원래 #54에 있었는데 EKS가 있는 이 스택으로 이동 — gitlab-runner는 스핀업/destroy를 반복해서 ECR을 같이 두면 안 됨)"
  type        = string
  default     = "rush-coupon-backend"
}
