terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.72"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# RDS가 manage_master_user_password로 자동 생성하는 Secrets Manager ARN을 ExternalSecret에
# 직접 꽂아주기 위해서만 쓴다 (eso-db-credentials.tf). ARN은 리소스 식별자라 git에 커밋하면
# 안 되는데, kustomize로 gitignored 값을 주입하는 방식은 ArgoCD가 그 파일을 절대 못 읽어서
# (ArgoCD는 git에 실제로 있는 내용만 봄) 동기화가 영구적으로 깨진다 — 그래서 이 ARN을
# 이미 알고 있는 Terraform이 직접 그 리소스 하나만 만든다. ALB Controller/ESO 같은
# 소프트웨어 설치는 계속 helm으로 한다 (AWS 리소스=Terraform, 클러스터 내부 앱=helm 원칙은
# 유지 — 이건 "AWS 리소스(ARN)를 클러스터로 전달하는 데이터"일 뿐 앱 설치가 아니다).
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
    env = {
      AWS_PROFILE = var.aws_profile
    }
  }
}
