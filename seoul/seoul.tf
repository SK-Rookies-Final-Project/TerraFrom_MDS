# Terraform Provider 설정
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }

    external = {
      source  = "hashicorp/external"  
      version = "~> 2.0"
    }
  }
}

# 로컬 변수 정의 - 키 파일 경로 확인
locals {
  private_key_path = "~/Desktop/ct/common/test-key.pem"
  key_name        = "test-key"
  key_exists      = fileexists(pathexpand("~/Desktop/ct/common/test-key.pem"))
}

# 기존 키 파일이 있는 경우 읽어오기
data "local_file" "existing_private_key" {
  count    = local.key_exists ? 1 : 0
  filename = pathexpand(local.private_key_path)
}

# 새 프라이빗 키 생성
resource "tls_private_key" "generated_key" {
  count     = local.key_exists ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

# 기존 퍼블릭 키에서 OpenSSH 형식으로 추출
data "external" "extract_public_key" {
  count   = local.key_exists ? 1 : 0
  program = ["sh", "-c", "openssl rsa -in ${pathexpand(local.private_key_path)} -pubout -outform DER | openssl pkey -pubin -inform DER -outform PEM | ssh-keygen -f /dev/stdin -i -m PKCS8 | awk '{print $1\" \"$2}' | jq -R '{public_key: .}'"]
}

# AWS 키 페어 생성
resource "aws_key_pair" "test_key" {
  key_name   = local.key_name
  public_key = local.key_exists ? data.external.extract_public_key[0].result.public_key : tls_private_key.generated_key[0].public_key_openssh

  tags = {
    Name = "test-key"
  }
}

# 생성된 프라이빗 키를 로컬 파일로 저장 (새로 생성된 경우에만)
resource "local_file" "private_key" {
  count           = local.key_exists ? 0 : 1
  content         = tls_private_key.generated_key[0].private_key_pem
  filename        = pathexpand(local.private_key_path)
  file_permission = "0600"
}

# AWS Provider 설정 - 서울 리전
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = "ap-northeast-2"
}

# IPv4 CIDR 블록 10.0.0.0/16으로 VPC 생성
# DNS 호스트명과 DNS 확인 활성화
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name = "ec2-instances"
  }
}

# 퍼블릭 서브넷에서 인터넷 접근을 위해 필요
resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "ec2-instances-igw"
  }
}

# ap-northeast-2a 가용 영역의 퍼블릭 서브넷 (10.0.1.0/24)
resource "aws_subnet" "public_subnet_2a" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "ec2-instances-public-2a"
    Type = "Public"
  }
}

# ap-northeast-2a 가용 영역의 프라이빗 서브넷 (10.0.11.0/24)
resource "aws_subnet" "private_subnet_2a" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name = "ec2-instances-private-2a"
    Type = "Private"
  }
}

# ap-northeast-2b 가용 영역의 프라이빗 서브넷 (10.0.12.0/24)
resource "aws_subnet" "private_subnet_2b" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "ap-northeast-2b"

  tags = {
    Name = "ec2-instances-private-2b"
    Type = "Private"
  }
}

# 퍼블릭 서브넷용 라우트 테이블 (인터넷 게이트웨이로 라우팅)
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }

  tags = {
    Name = "ec2-instances-public-rt"
  }
}

# 프라이빗 서브넷용 라우트 테이블 (로컬 트래픽만)
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "ec2-instances-private-rt"
  }
}

# 퍼블릭 서브넷을 퍼블릭 라우트 테이블에 연결
resource "aws_route_table_association" "public_2a_association" {
  subnet_id      = aws_subnet.public_subnet_2a.id
  route_table_id = aws_route_table.public_route_table.id
}

# 프라이빗 서브넷을 프라이빗 라우트 테이블에 연결
resource "aws_route_table_association" "private_2a_association" {
  subnet_id      = aws_subnet.private_subnet_2a.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_2b_association" {
  subnet_id      = aws_subnet.private_subnet_2b.id
  route_table_id = aws_route_table.private_route_table.id
}

# RDS용 DB 서브넷 그룹 생성
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [
    aws_subnet.private_subnet_2a.id,
    aws_subnet.private_subnet_2b.id
  ]

  tags = {
    Name = "RDS subnet group"
  }
}

# Ubuntu 24.04 LTS AMI 조회
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# EC2 인스턴스용 보안 그룹
resource "aws_security_group" "ec2_instances_sg" {
  name        = "ec2-instances-sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main_vpc.id

  # 모든 TCP 포트 허용 (인스턴스 간 통신)
  ingress {
    description = "All TCP traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH 접근 허용
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-instances-sg"
  }
}

# EC2 인스턴스들
# Controller 인스턴스 (t3.medium) - 3대
resource "aws_instance" "controller" {
  count                  = 3
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  key_name              = aws_key_pair.test_key.key_name
  subnet_id             = aws_subnet.public_subnet_2a.id
  vpc_security_group_ids = [aws_security_group.ec2_instances_sg.id]

  # 퍼블릭 IP 자동 할당 활성화
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name = "CP1_Controller${count.index + 1}_A"
    Type = "Controller"
  }

  # 키 페어가 생성될 때까지 대기
  depends_on = [aws_key_pair.test_key]
}

# Broker 인스턴스 (t3.large) - 3대
resource "aws_instance" "broker" {
  count                  = 3
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  key_name              = aws_key_pair.test_key.key_name
  subnet_id             = aws_subnet.public_subnet_2a.id
  vpc_security_group_ids = [aws_security_group.ec2_instances_sg.id]

  # 퍼블릭 IP 자동 할당 활성화
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name = count.index == 0 ? "CP1_Broker1_A" : count.index == 1 ? "CP1_Broker2_A" : "CP1_Broker3_A"
    Type = "Broker"
  }

  # 키 페어가 생성될 때까지 대기
  depends_on = [aws_key_pair.test_key]
}

# Connect Worker 인스턴스 (t3.medium) - 2대
resource "aws_instance" "connect_worker" {
  count                  = 2
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  key_name              = aws_key_pair.test_key.key_name
  subnet_id             = aws_subnet.public_subnet_2a.id
  vpc_security_group_ids = [aws_security_group.ec2_instances_sg.id]

  # 퍼블릭 IP 자동 할당 활성화
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name = "CP1_Connect${count.index + 1}_A"
    Type = "Connect-Worker"
  }

  # 키 페어가 생성될 때까지 대기
  depends_on = [aws_key_pair.test_key]
}

# Schema Registry 인스턴스 (t3.small) - 2대
resource "aws_instance" "schema_registry" {
  count                  = 2
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name              = aws_key_pair.test_key.key_name
  subnet_id             = aws_subnet.public_subnet_2a.id
  vpc_security_group_ids = [aws_security_group.ec2_instances_sg.id]

  # 퍼블릭 IP 자동 할당 활성화
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name = "CP1_SR${count.index + 1}_A"
    Type = "Schema-Registry"
  }

  # 키 페어가 생성될 때까지 대기
  depends_on = [aws_key_pair.test_key]
}

# Confluent Control Center 인스턴스 (t3.large) - 1대
resource "aws_instance" "control_center" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  key_name              = aws_key_pair.test_key.key_name
  subnet_id             = aws_subnet.public_subnet_2a.id
  vpc_security_group_ids = [aws_security_group.ec2_instances_sg.id]

  # 퍼블릭 IP 자동 할당 활성화
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name = "CP1_C3_A"
    Type = "Control-Center"
  }

  # 키 페어가 생성될 때까지 대기
  depends_on = [aws_key_pair.test_key]
}

# EIP 할당 - Broker 3개
resource "aws_eip" "broker_eip" {
  count    = 3
  instance = aws_instance.broker[count.index].id
  domain   = "vpc"

  tags = {
    Name = "Broker${count.index + 1}-EIP"
  }

  depends_on = [aws_instance.broker]
}

# EIP 할당 - Schema Registry 2개
resource "aws_eip" "schema_registry_eip" {
  count    = 2
  instance = aws_instance.schema_registry[count.index].id
  domain   = "vpc"

  tags = {
    Name = "Schema-Registry${count.index + 1}-EIP"
  }

  depends_on = [aws_instance.schema_registry]
}

# RDS용 보안 그룹
resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Security group for RDS instances"
  vpc_id      = aws_vpc.main_vpc.id

  # PostgreSQL 접근 허용 (포트 5432) - 모든 곳에서 IPv4/IPv6
  ingress {
    from_port        = 5432
    to_port          = 5432
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]      # IPv4
    ipv6_cidr_blocks = ["::/0"]           # IPv6
    description      = "PostgreSQL access from anywhere"
  }

  # MySQL/Aurora 접근 허용 (포트 3306) - EC2 보안 그룹에서
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description     = "MySQL access from anywhere"
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name = "rds-security-group"
  }
}

# MySQL RDS 인스턴스
resource "aws_db_instance" "mysql" {
  identifier                = "tgmysqldb"
  allocated_storage         = 20
  storage_type              = "gp2"
  engine                    = "mysql"
  engine_version            = "8.0"
  instance_class            = "db.t3.micro"
  db_name                   = "tgmysqlDB"
  username                  = "tgadmin"
  password                  = "tgmaster!"
  parameter_group_name      = "default.mysql8.0"
  option_group_name         = "default:mysql-8-0"
  
  # 네트워크 설정
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  db_subnet_group_name      = aws_db_subnet_group.rds_subnet_group.name

  # 기타 설정
  publicly_accessible      = true
  storage_encrypted        = true
  deletion_protection      = false

  # 속도 향상
  skip_final_snapshot      = true
  delete_automated_backups  = true
  backup_retention_period   = 0
  backup_window            = null

  tags = {
    Name = "TG MySQL Database"
    Type = "MySQL"
  }
}

# PostgreSQL RDS 인스턴스
resource "aws_db_instance" "postgresql" {
  identifier                = "tgpostgresql"
  allocated_storage         = 20
  storage_type              = "gp3"
  engine                    = "postgres"
  engine_version            = "16.3"
  instance_class            = "db.t4g.micro"
  db_name                   = "tgpostgreDB"
  username                  = "tgadmin"
  password                  = "tgmaster!"
  parameter_group_name      = "default.postgres16"
  
  # 네트워크 설정
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  db_subnet_group_name      = aws_db_subnet_group.rds_subnet_group.name

  # 기타 설정
  publicly_accessible      = true
  storage_encrypted        = true
  deletion_protection      = false

  # 속도 향상
  skip_final_snapshot      = true
  delete_automated_backups  = true
  backup_retention_period   = 0
  backup_window            = null

  tags = {
    Name = "TG PostgreSQL Database"
    Type = "PostgreSQL"
  }
}

# EC2 인스턴스 정보 출력
output "controller_instances" {
  description = "Controller 인스턴스 정보"
  value = {
    for idx, instance in aws_instance.controller : 
    "controller-${idx + 1}" => {
      instance_id = instance.id
      public_ip   = instance.public_ip
      private_ip  = instance.private_ip
      name        = instance.tags.Name
    }
  }
}

output "broker_instances" {
  description = "Broker 인스턴스 정보"
  value = {
    for idx, instance in aws_instance.broker : 
    "broker-${idx + 1}" => {
      instance_id = instance.id
      public_ip   = instance.public_ip
      private_ip  = instance.private_ip
      elastic_ip  = aws_eip.broker_eip[idx].public_ip
      name        = instance.tags.Name
    }
  }
}

output "connect_worker_instances" {
  description = "Connect Worker 인스턴스 정보"
  value = {
    for idx, instance in aws_instance.connect_worker : 
    "connect-worker-${idx + 1}" => {
      instance_id = instance.id
      public_ip   = instance.public_ip
      private_ip  = instance.private_ip
      name        = instance.tags.Name
    }
  }
}

output "schema_registry_instances" {
  description = "Schema Registry 인스턴스 정보"
  value = {
    for idx, instance in aws_instance.schema_registry : 
    "schema-registry-${idx + 1}" => {
      instance_id = instance.id
      public_ip   = instance.public_ip
      private_ip  = instance.private_ip
      elastic_ip  = aws_eip.schema_registry_eip[idx].public_ip
      name        = instance.tags.Name
    }
  }
}

output "control_center_instance" {
  description = "Control Center 인스턴스 정보"
  value = {
    instance_id = aws_instance.control_center.id
    public_ip   = aws_instance.control_center.public_ip
    private_ip  = aws_instance.control_center.private_ip
    name        = aws_instance.control_center.tags.Name
  }
}

# 네트워크 정보 출력
output "vpc_info" {
  description = "VPC 정보"
  value = {
    vpc_id     = aws_vpc.main_vpc.id
    cidr_block = aws_vpc.main_vpc.cidr_block
  }
}

output "subnet_info" {
  description = "서브넷 정보"
  value = {
    public_subnet_2a = {
      id         = aws_subnet.public_subnet_2a.id
      cidr_block = aws_subnet.public_subnet_2a.cidr_block
      az         = aws_subnet.public_subnet_2a.availability_zone
    }
    private_subnet_2a = {
      id         = aws_subnet.private_subnet_2a.id
      cidr_block = aws_subnet.private_subnet_2a.cidr_block
      az         = aws_subnet.private_subnet_2a.availability_zone
    }
    private_subnet_2b = {
      id         = aws_subnet.private_subnet_2b.id
      cidr_block = aws_subnet.private_subnet_2b.cidr_block
      az         = aws_subnet.private_subnet_2b.availability_zone
    }
  }
}

# RDS 정보 출력
output "rds_mysql_info" {
  description = "MySQL RDS 정보"
  value = {
    endpoint = aws_db_instance.mysql.endpoint
    port     = aws_db_instance.mysql.port
    db_name  = aws_db_instance.mysql.db_name
    username = aws_db_instance.mysql.username
  }
  sensitive = false
}

output "rds_postgresql_info" {
  description = "PostgreSQL RDS 정보"
  value = {
    endpoint = aws_db_instance.postgresql.endpoint
    port     = aws_db_instance.postgresql.port
    db_name  = aws_db_instance.postgresql.db_name
    username = aws_db_instance.postgresql.username
  }
  sensitive = false
}

# 키 페어 정보 출력
output "key_pair_info" {
  description = "키 페어 정보"
  value = {
    key_name        = aws_key_pair.test_key.key_name
    private_key_path = local.private_key_path
  }
}

# SSH 접속 명령어 출력 (편의용)
output "ssh_commands" {
  description = "SSH 접속 명령어"
  value = {
    controller_ssh = [
      for idx, instance in aws_instance.controller :
      "ssh -i ${local.private_key_path} ubuntu@${instance.public_ip} # ${instance.tags.Name}"
    ]
    broker_ssh = [
      for idx, instance in aws_instance.broker :
      "ssh -i ${local.private_key_path} ubuntu@${aws_eip.broker_eip[idx].public_ip} # ${instance.tags.Name}"
    ]
    connect_worker_ssh = [
      for idx, instance in aws_instance.connect_worker :
      "ssh -i ${local.private_key_path} ubuntu@${instance.public_ip} # ${instance.tags.Name}"
    ]
    schema_registry_ssh = [
      for idx, instance in aws_instance.schema_registry :
      "ssh -i ${local.private_key_path} ubuntu@${aws_eip.schema_registry_eip[idx].public_ip} # ${instance.tags.Name}"
    ]
    control_center_ssh = "ssh -i ${local.private_key_path} ubuntu@${aws_instance.control_center.public_ip} # ${aws_instance.control_center.tags.Name}"
  }
}