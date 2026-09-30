data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}

resource "aws_instance" "gitlab_runner" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.gitlab_runner.id]
  iam_instance_profile   = aws_iam_instance_profile.gitlab_runner.name
  key_name               = aws_key_pair.this.key_name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  # backend-build 잡이 docker executor 컨테이너 안에서 aws ecr get-login-password로
  # 이 인스턴스의 IAM 역할 자격증명을 가져와야 하는데, 컨테이너에서의 IMDS 접근은
  # 호스트 대비 1홉 더 거쳐서 기본값(hop limit 1)으로는 막힌다. 2로 올려서 허용한다.
  metadata_options {
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    ssm_parameter_name   = aws_ssm_parameter.tailscale_authkey.name
    region               = var.region
    hostname             = var.name_prefix
    gitlab_registry_port = var.gitlab_registry_port
  })

  tags = {
    Name = "${var.name_prefix}-ec2"
  }

  # user_data가 부팅 즉시 SSM 파라미터를 조회하므로, 그 권한(IAM 역할 정책)이
  # 먼저 붙어있지 않으면 첫 부팅 시 조회가 실패한다 — 명시적으로 순서를 강제한다.
  depends_on = [aws_iam_role_policy.ssm_tailscale_authkey]
}
