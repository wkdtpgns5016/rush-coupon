# Tailscale authkey 전용. EC2가 tailnet에 붙기 전엔 다른 통신 수단이 없어서
# 이 값만은 부팅 시점에 인스턴스가 직접 가져와야 한다 (다른 시크릿은 절대 여기 넣지 않는다 —
# GITHUB_PAT/DB비번/SSH키는 Mac에서 DOCKER_HOST로 원격 조작하는 설계라 EC2가 알 필요가 없다).
#
# value_wo(write-only)라 apply 시점에만 값이 전달되고 state 파일엔 저장되지 않는다.
# 키를 교체할 땐 tailscale_authkey_version을 1 올려야 갱신이 트리거된다.
resource "aws_ssm_parameter" "tailscale_authkey" {
  name        = "/${var.name_prefix}/tailscale-authkey"
  description = "Tailscale ephemeral auth key for ${var.name_prefix} EC2 bootstrap"
  type        = "SecureString"

  value_wo         = var.tailscale_authkey
  value_wo_version = var.tailscale_authkey_version

  tags = {
    Name = "${var.name_prefix}-tailscale-authkey"
  }
}
