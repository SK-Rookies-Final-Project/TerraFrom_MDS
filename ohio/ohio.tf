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

# AWS Provider 설정 - 오하이오 리전
provider "aws" {
    access_key = var.aws_access_key
    secret_key = var.aws_secret_key
    region = "us-east-2"
}

# IPv4 CIDR 블록 10.0.0.0/16으로 VPC 생성
# DNS 호스트명과 DNS 확인 활성화
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name = "docker-compose"
  }
}

# 퍼블릭 서브넷에서 인터넷 접근을 위해 필요
resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "docker-compose-igw"
  }
}

# us-east-2a 가용 영역의 퍼블릭 서브넷 (10.0.1.0/24)
resource "aws_subnet" "public_subnet_2a" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "docker-compose-public-2a"
    Type = "Public"
  }
}

# us-east-2a 가용 영역의 프라이빗 서브넷 (10.0.11.0/24)
resource "aws_subnet" "private_subnet_2a" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "us-east-2a"

  tags = {
    Name = "docker-compose-private-2a"
    Type = "Private"
  }
}

# us-east-2b 가용 영역의 프라이빗 서브넷 (10.0.12.0/24)
resource "aws_subnet" "private_subnet_2b" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "us-east-2b"

  tags = {
    Name = "docker-compose-private-2b"
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
    Name = "docker-compose-public-rt"
  }
}

# 프라이빗 서브넷용 라우트 테이블 (로컬 트래픽만)
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "docker-compose-private-rt"
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
resource "aws_security_group" "docker_compose_sg" {
  name        = "docker-compose-sg"
  description = "Security group for Docker Compose EC2 instance"
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
    Name = "docker-compose-sg"
  }
}

# EC2 인스턴스 생성
resource "aws_instance" "docker_compose" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "m5.xlarge"
  key_name              = aws_key_pair.test_key.key_name
  subnet_id             = aws_subnet.public_subnet_2a.id
  vpc_security_group_ids = [aws_security_group.docker_compose_sg.id]
  
  # 퍼블릭 IP 자동 할당 활성화
  associate_public_ip_address = true

  # EBS 볼륨 설정 (루트 볼륨)
  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
    
    tags = {
      Name = "Docker_Compose-root"
    }
  }

  tags = {
    Name = "Docker_Compose"
    Type = "Docker Server"
  }

  # 키 페어가 생성될 때까지 대기
  depends_on = [aws_key_pair.test_key]
}

# EIP 할당 - Docker Container
resource "aws_eip" "docker_compose_eip" {
  count       = 1
  instance    = aws_instance.docker_compose.id
  domain      = "vpc"
  tags = {
    Name = "DockerCompose-EIP"
  }

  depends_on = [aws_instance.docker_compose]
}

# RDS용 보안 그룹
resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Security group for RDS instances"
  vpc_id      = aws_vpc.main_vpc.id

  # PostgreSQL 접근 허용 (포트 5432) - 모든 곳에서
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "PostgreSQL access from anywhere"
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
  publicly_accessible      = true # 개발 단계
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
  publicly_accessible      = true # 개발 단계
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

# 다른 리소스에서 참조할 수 있도록 주요 값들을 출력
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main_vpc.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = [aws_subnet.public_subnet_2a.id]
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록"
  value       = [aws_subnet.private_subnet_2a.id]
}

# EC2 인스턴스 정보
output "ec2_instance_id" {
  description = "EC2 인스턴스 ID"
  value       = aws_instance.docker_compose.id
}

output "ec2_public_ip" {
  description = "EC2 인스턴스 퍼블릭 IP"
  value       = aws_instance.docker_compose.public_ip
}

output "ec2_private_ip" {
  description = "EC2 인스턴스 프라이빗 IP"
  value       = aws_instance.docker_compose.private_ip
}

# RDS 인스턴스 정보
output "mysql_endpoint" {
  description = "MySQL RDS 엔드포인트"
  value       = aws_db_instance.mysql.endpoint
}

output "mysql_port" {
  description = "MySQL RDS 포트"
  value       = aws_db_instance.mysql.port
}

output "postgresql_endpoint" {
  description = "PostgreSQL RDS 엔드포인트"
  value       = aws_db_instance.postgresql.endpoint
}

output "postgresql_port" {
  description = "PostgreSQL RDS 포트"
  value       = aws_db_instance.postgresql.port
}

# 보안 그룹 정보
output "ec2_security_group_id" {
  description = "EC2 보안 그룹 ID"
  value       = aws_security_group.docker_compose_sg.id
}

output "rds_security_group_id" {
  description = "RDS 보안 그룹 ID"
  value       = aws_security_group.rds_sg.id
}

# SSH 연결을 위한 정보
output "ssh_connection_command" {
  description = "EC2 인스턴스 SSH 연결 명령어"
  value       = "ssh -i ${local.private_key_path} ubuntu@${aws_instance.docker_compose.public_ip}"
}