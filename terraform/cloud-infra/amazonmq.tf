# Amazon MQ(aws_mq_broker)는 RDS의 manage_master_user_password 같은 자동 관리 기능이 없어서,
# random_password로 생성해 state에 저장한다 (단기 검증용 스택이라 로컬 state 노출 리스크를
# #54의 ssh_public_key 등과 동일한 수준으로 수용 — 영구 운영 환경이면 Secrets Manager +
# write-only 인자로 바꿔야 함).
resource "random_password" "mq" {
  length  = 20
  special = false # Amazon MQ 비밀번호는 특수문자 제약이 있어 영숫자로만 생성
}

resource "aws_mq_broker" "this" {
  broker_name        = "${var.name_prefix}-rabbitmq"
  engine_type        = "RabbitMQ"
  engine_version     = var.mq_engine_version
  host_instance_type = var.mq_instance_type
  deployment_mode    = "SINGLE_INSTANCE" # 비용 때문에 클러스터 모드 아님 — M6은 HA 시연 대상 아님

  # RabbitMQ 4.3부터 AWS가 이 옵션을 필수로 요구함 (false면 CreateBroker 자체가 거부됨)
  auto_minor_version_upgrade = true

  publicly_accessible = false
  subnet_ids          = [aws_subnet.private[0].id] # SINGLE_INSTANCE는 서브넷 1개만 허용
  security_groups     = [aws_security_group.mq.id]

  user {
    username = var.mq_username
    password = random_password.mq.result
  }

  tags = {
    Name = "${var.name_prefix}-rabbitmq"
  }
}
