output "instance_id" {
  value = aws_instance.gitlab_runner.id
}

output "instance_private_ip" {
  description = "VPC 내부 IP (Tailscale IP는 부팅 후 인스턴스에서 `tailscale ip -4`로 별도 확인)"
  value       = aws_instance.gitlab_runner.private_ip
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "nat_gateway_id" {
  description = "destroy 시 EIP/NAT 과금이 멈췄는지 확인용"
  value       = aws_nat_gateway.this.id
}

output "tailscale_hostname" {
  description = "user_data가 tailscale up --hostname으로 등록하는 이름 — bootstrap-and-verify.sh가 tailscale status에서 이 이름으로 인스턴스를 찾는다"
  value       = var.name_prefix
}
