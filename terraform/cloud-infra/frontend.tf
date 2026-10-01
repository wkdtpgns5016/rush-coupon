# #59: 프론트엔드 정적 호스팅 (S3 + CloudFront, OAC로 S3는 CloudFront에서만 접근)
#
# 커스텀 도메인은 쓰지 않는다 — ACM 인증서(us-east-1 고정)/Route53/도메인 소유가 전부
# 추가로 필요한데, 포트폴리오 성격상 과한 범위라 CloudFront 기본 도메인(*.cloudfront.net)만
# 쓴다. 기본 도메인도 AWS가 자동으로 유효한 HTTPS를 제공해서 보안상 문제 없다.
#
# 버킷 이름은 S3가 전역 네임스페이스라 겹침을 피하려고 계정 ID를 붙인다 — 이 값은
# AWS가 무작위로 만든 비밀이 아니라 ECR_REPOSITORY_URL 등 이미 공개된 값에서도
# 유도 가능해서, 결과 버킷 이름을 CI 변수로 등록해도 노출 문제가 없다.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  # force_destroy 없으면 frontend-deploy-cloud가 aws s3 sync로 객체를 채운 뒤
  # teardown.sh의 terraform destroy가 "bucket not empty"로 실패한다.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name_prefix}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # SPA는 아니지만(react-router 등 클라이언트 라우팅 없음), S3+OAC 조합은 존재하지
  # 않는 경로 요청에 403을 주므로 index.html로 떨어뜨려 둔다.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
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

# OAC: 이 CloudFront 배포(SourceArn 조건)에서만 S3 GetObject를 허용 — 버킷 자체는
# 퍼블릭 액세스 완전 차단 상태를 유지한다.
data "aws_iam_policy_document" "frontend_oac" {
  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_oac.json
}
