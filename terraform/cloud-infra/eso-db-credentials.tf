# backend-db-credentials-auth라는 ExternalSecret 하나만 Terraform이 직접 만든다.
# 왜 다른 ExternalSecret들(deploy 브랜치, ArgoCD 추적)과 다르게 여기 있는지는
# versions.tf의 kubernetes provider 설명 참고 — RDS Secrets Manager ARN이 실제
# 리소스 식별자라 git에 커밋할 수 없어서다. aws-secrets-manager SecretStore 자체는
# 계속 deploy 브랜치(ArgoCD 추적)에 있고, 여기선 그 이름만 참조한다.
resource "kubernetes_manifest" "backend_db_credentials_auth" {
  # 노드 그룹보다 먼저 지워져야 한다 — 암묵적 의존성(kubernetes provider가
  # aws_eks_cluster.this.endpoint를 씀)은 컨트롤플레인만 묶어주고 노드 그룹과는
  # 무관해서, depends_on 없이는 destroy 때 Terraform이 이 리소스와 노드 그룹을
  # 병렬로 지운다. 그러면 ESO 컨트롤러(파드)가 먼저 사라져서 이 리소스의
  # finalizer(externalsecret-cleanup)를 아무도 못 지워 destroy가 멈춘다
  # (실제로 겪음 — kubectl로 finalizer를 수동 제거해서 풀었다).
  depends_on = [aws_eks_node_group.this]

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "backend-db-credentials-auth"
      namespace = "rush-coupon"
    }
    spec = {
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "SecretStore"
      }
      target = {
        name           = "backend-db-credentials"
        creationPolicy = "Merge"
      }
      data = [
        {
          secretKey = "DB_USERNAME"
          remoteRef = {
            key      = aws_db_instance.this.master_user_secret[0].secret_arn
            property = "username"
          }
        },
        {
          secretKey = "DB_PASSWORD"
          remoteRef = {
            key      = aws_db_instance.this.master_user_secret[0].secret_arn
            property = "password"
          }
        }
      ]
    }
  }
}
