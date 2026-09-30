terraform {
  # ephemeral 변수 + write-only 인자(aws_ssm_parameter.value_wo) 사용에 1.11+ 필요
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.72" # aws_ssm_parameter의 value_wo 지원 최소 버전
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
