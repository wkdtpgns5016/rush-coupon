# 프라이빗 서브넷(IGW 라우트 없음)이라 인터넷發 인바운드 자체가 라우팅 단계에서 불가능하다.
# SSH도 Tailscale(WireGuard, outbound로 시작되는 세션의 stateful 리턴 트래픽)로만 붙으므로
# 인그레스 규칙이 전혀 필요 없다 — 이 SG는 이그레스 전체 허용만 갖는다.
resource "aws_security_group" "gitlab_runner" {
  name        = "${var.name_prefix}-sg"
  description = "GitLab+Runner EC2 - outbound only, no inbound rules needed"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg"
  }
}
