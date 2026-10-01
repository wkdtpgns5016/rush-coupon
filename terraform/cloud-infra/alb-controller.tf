# AWS Load Balancer Controller가 쓸 IRSA 역할. 컨트롤러 자체(Helm 설치)는
# Terraform 밖에서 install-alb-controller.sh로 설치한다 — 이 파일은 그 설치가
# AWS API를 호출할 수 있게 해주는 IAM 쪽 재료만 준비한다
# (원칙: AWS 리소스는 Terraform, 클러스터 내부 앱은 helm/kubectl).
#
# alb-controller-iam-policy.json은 AWS 공식 배포본을 그대로 받아온 것:
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.name_prefix}-alb-controller-policy"
  policy = file("${path.module}/alb-controller-iam-policy.json")
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.name_prefix}-alb-controller-role"

  # 특정 ServiceAccount(kube-system/aws-load-balancer-controller)에서만
  # 이 역할을 assume할 수 있도록 OIDC sub 클레임으로 제한 (IRSA 표준 패턴)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}
