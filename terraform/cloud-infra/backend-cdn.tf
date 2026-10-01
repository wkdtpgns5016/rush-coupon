# backend ALB는 HTTP만 지원한다 — ALB에 직접 HTTPS를 붙이려면 커스텀 도메인+ACM
# 인증서가 필요한데(frontend 때 피하기로 한 바로 그 복잡도), frontend.tf와 같은 트릭을
# 여기도 쓴다: CloudFront를 ALB 앞에 하나 더 둬서 CloudFront 기본 도메인의 HTTPS를
# 그대로 가져다 쓴다. 프론트(CloudFront, HTTPS)에서 백엔드를 http://ALB로 그대로
# 부르면 Mixed Content로 브라우저가 차단한다(실제로 겪음) — 이 CloudFront가 그 중간다리.
#
# backend ALB는 ArgoCD(Kubernetes Ingress)가 나중에 만드는 리소스라 Terraform이 맨 처음
# apply할 때는 존재하지 않는다(teardown.sh의 "ALB Controller가 만든 ALB는 Terraform이
# 모르는 리소스" 설명과 같은 맥락). 그래서 이 리소스 전체를 var.enable_backend_cdn으로
# 묶어 count=0일 땐 kubernetes_ingress_v1 데이터 소스 자체를 평가하지 않게 한다 — 첫
# terraform apply(ALB가 아직 없음)는 이 변수가 false인 채로 끝나고, install-all.sh가
# bootstrap-backend-app.sh로 ALB를 만든 뒤 backend-cdn.auto.tfvars에 true를 써서
# 두 번째 apply로 이 리소스를 완성한다.
variable "enable_backend_cdn" {
  description = "backend Ingress(ALB)가 생긴 뒤에만 true — install-all.sh가 자동으로 관리한다"
  type        = bool
  default     = false
}

data "kubernetes_ingress_v1" "backend" {
  count = var.enable_backend_cdn ? 1 : 0

  metadata {
    name      = "backend"
    namespace = "rush-coupon"
  }
}

locals {
  backend_alb_hostname = var.enable_backend_cdn ? data.kubernetes_ingress_v1.backend[0].status[0].load_balancer[0].ingress[0].hostname : ""
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# API 요청이라 쿠키/쿼리스트링/대부분의 헤더를 그대로 origin에 전달해야 한다 — 정적
# 자산용 CachingOptimized와 달리 Host 헤더만 빼고 전부 넘기는 이 정책을 쓴다.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "backend" {
  count = var.enable_backend_cdn ? 1 : 0

  enabled = true

  origin {
    domain_name = local.backend_alb_hostname
    origin_id   = "alb-backend"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "alb-backend"
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
