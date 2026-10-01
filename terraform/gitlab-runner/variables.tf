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

# #59 frontend-deploy-cloud 잡의 IAM 정책이 S3 버킷 ARN을 좁히려고 필요 — cloud-infra
# 스택이 state를 따로 가져서 리소스 참조 대신 그쪽 name_prefix 값을 변수로 복제한다.
# cloud-infra/variables.tf의 name_prefix 기본값과 같아야 한다.
variable "cloud_infra_name_prefix" {
  description = "terraform/cloud-infra 스택의 name_prefix (frontend 버킷 이름 계산용)"
  type        = string
  default     = "rush-coupon-cloud"
}

# most_recent=true인 data "aws_ami" 조회로 매번 최신 AMI를 가져오면, Canonical이
# 패치 이미지를 새로 낼 때마다 무관한 apply(예: IAM 정책 추가)에도 인스턴스 재생성이
# 끼어든다(실제로 겪음) — 그래서 조회 결과를 변수로 고정해 "언제 갱신할지"를 의도적인
# 선택으로 바꾼다. 갱신하려면 아래로 최신 AMI ID를 조회해서 default를 바꾼다:
#   aws ec2 describe-images --owners 099720109477 \
#     --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
#               "Name=virtualization-type,Values=hvm" \
#     --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text \
#     --region ap-northeast-2 --profile rush-coupon-admin
variable "ami_id" {
  description = "GitLab Runner EC2 AMI (Ubuntu 22.04 jammy, ap-northeast-2) — 고정값, 갱신 방법은 위 주석 참고"
  type        = string
  # 지금 떠 있는 인스턴스가 실제로 이 AMI로 생성됐다(terraform state 확인) — 더 최신
  # AMI가 아니라 이 값으로 고정해야 이번(무관한 IAM 정책 추가) apply에서 재생성이 안 걸린다.
  default = "ami-0efae34c528c68a9c"
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

