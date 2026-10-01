variable "region" {
  description = "리소스를 생성할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "사용할 AWS CLI profile (aws login으로 만든 dev-rush-coupon-admin 자격증명). AWS_PROFILE 환경변수를 안 잡아도 항상 이 계정을 쓰도록 provider에 고정한다"
  type        = string
  default     = "rush-coupon-admin"
}

variable "name_prefix" {
  description = "생성되는 리소스 이름/태그 접두사"
  type        = string
  default     = "rush-coupon-gitlab-runner"
}

variable "az" {
  description = "서브넷을 생성할 가용영역"
  type        = string
  default     = "ap-northeast-2a"
}

variable "vpc_cidr" {
  description = "이 스택 전용 VPC CIDR (#55 EKS VPC와 별개)"
  type        = string
  default     = "10.60.0.0/16"
}

variable "public_subnet_cidr" {
  description = "NAT Gateway를 둘 퍼블릭 서브넷 CIDR"
  type        = string
  default     = "10.60.0.0/24"
}

variable "private_subnet_cidr" {
  description = "GitLab+Runner EC2를 둘 프라이빗 서브넷 CIDR"
  type        = string
  default     = "10.60.1.0/24"
}

variable "instance_type" {
  description = "GitLab CE + Runner를 함께 띄울 EC2 인스턴스 타입"
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "루트 EBS 볼륨 크기(GB) — GitLab 데이터 + docker 이미지 저장 공간"
  type        = number
  default     = 40
}

variable "ssh_public_key" {
  description = "EC2 접속용 SSH 공개키 내용 (예: $(cat ~/.ssh/id_ed25519.pub))"
  type        = string
}

variable "tailscale_authkey" {
  description = "인스턴스 부팅 시 tailnet에 조인할 Tailscale auth key (https://login.tailscale.com/admin/settings/keys 에서 발급, ephemeral 권장). ephemeral 변수라 plan/state 어디에도 저장되지 않고 SSM Parameter Store의 write-only 인자로만 흘러간다"
  type        = string
  ephemeral   = true
}

variable "tailscale_authkey_version" {
  description = "tailscale_authkey를 교체(로테이션)할 때마다 1씩 올린다 — write-only 값이라 Terraform이 변경 여부를 스스로 판단 못 해서 이 값으로 갱신을 트리거한다"
  type        = number
  default     = 1
}

variable "gitlab_registry_port" {
  description = "GitLab Container Registry 포트 (deploy/gitlab/docker-compose.yml의 GITLAB_REGISTRY_PORT와 같은 값이어야 함)"
  type        = number
  default     = 5050
}

