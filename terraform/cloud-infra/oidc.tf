# ALB Controller(#56)/External Secrets Operator(#57)가 IRSA(IAM Roles for Service Accounts)로
# AWS 자격증명을 받으려면, 클러스터의 OIDC issuer를 IAM에 OIDC Provider로 등록해둬야 한다.
# 표준 Terraform EKS IRSA 부트스트랩 패턴.

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.name_prefix}-eks-oidc"
  }
}
