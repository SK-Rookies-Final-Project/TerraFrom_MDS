#!/bin/bash

set -e  # 에러 발생 시 스크립트 중단

# AWS 기본 리전 설정
AWS_REGION="${AWS_REGION:-ap-east-2}"

# 색상 정의 (출력 가독성을 위해)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 운영체제별 sed 명령어 처리
sed_inplace() {
    local pattern="$1"
    local file="$2"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS (BSD sed)
        sed -i '' "$pattern" "$file"
    else
        # Linux (GNU sed)
        sed -i "$pattern" "$file"
    fi
}

# AWS CLI 설치 및 설정 확인
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI가 설치되지 않았습니다. AWS CLI를 먼저 설치해주세요."
        exit 1
    fi
    
    # AWS 자격 증명 확인
    if ! aws sts get-caller-identity --region $AWS_REGION &> /dev/null; then
        log_error "AWS 자격 증명이 설정되지 않았습니다. 'aws configure'를 실행해주세요."
        exit 1
    fi
    
    log_success "AWS CLI 설정이 정상적으로 확인되었습니다."
    log_info "사용 중인 AWS 리전: $AWS_REGION"
}

# 모든 실행 중인 인스턴스 목록 출력
list_running_instances() {
    log_info "현재 실행 중인 모든 인스턴스 목록을 조회합니다... (리전: $AWS_REGION)"
    echo
    aws ec2 describe-instances \
        --region $AWS_REGION \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress,InstanceId]' \
        --output table
    echo
}

# 인스턴스 정보 가져오기 (유연한 검색)
get_instance_info() {
    local instance_name="$1"
    
    log_info "인스턴스 '$instance_name' 정보를 조회 중... (리전: $AWS_REGION)"
    
    # 먼저 정확한 이름으로 검색
    local instance_info=$(aws ec2 describe-instances \
        --region $AWS_REGION \
        --filters "Name=tag:Name,Values=$instance_name" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].[PublicIpAddress,PublicDnsName,InstanceId,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    
    # 정확한 이름으로 찾지 못한 경우, 부분 일치 검색
    if [[ -z "$instance_info" ]]; then
        log_warning "정확한 이름 '$instance_name'으로 인스턴스를 찾을 수 없습니다."
        log_info "유사한 이름의 인스턴스를 검색합니다..."
        
        # 대소문자 구분 없이 Docker나 Compose가 포함된 인스턴스 검색
        local similar_instances=$(aws ec2 describe-instances \
            --region $AWS_REGION \
            --filters "Name=instance-state-name,Values=running" \
            --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],PublicIpAddress,PublicDnsName,InstanceId]' \
            --output text 2>/dev/null | grep -i -E "(docker|compose)")
        
        if [[ -n "$similar_instances" ]]; then
            log_info "Docker/Compose가 포함된 실행 중인 인스턴스들:"
            echo "$similar_instances" | while read name ip dns id; do
                log_info "  - 이름: $name, IP: $ip, DNS: $dns, ID: $id"
            done
            echo
            
            # 사용자에게 선택 옵션 제공
            log_warning "위 인스턴스 중 사용할 인스턴스의 정확한 이름을 입력하거나,"
            log_warning "스크립트를 종료한 후 올바른 인스턴스 이름으로 다시 실행해주세요."
            return 1
        fi
    fi
    
    if [[ -z "$instance_info" ]]; then
        log_error "실행 중인 '$instance_name' 인스턴스를 찾을 수 없습니다."
        log_warning "다음 명령어로 인스턴스 목록을 확인해보세요:"
        log_warning "aws ec2 describe-instances --region $AWS_REGION --query 'Reservations[*].Instances[*].[Tags[?Key==\`Name\`].Value|[0],State.Name,PublicIpAddress]' --output table"
        list_running_instances
        return 1
    fi
    
    # 첫 번째 결과 사용 (여러 인스턴스가 있을 경우)
    read -r public_ip public_dns instance_id <<< $(echo "$instance_info" | head -n1)
    
    if [[ "$public_ip" == "None" ]] || [[ -z "$public_ip" ]]; then
        log_error "인스턴스 '$instance_name'에 퍼블릭 IP가 할당되지 않았습니다."
        exit 1
    fi
    
    log_success "인스턴스 정보 조회 완료:"
    log_info "  - 인스턴스 ID: $instance_id"
    log_info "  - 퍼블릭 IP: $public_ip"
    log_info "  - 퍼블릭 DNS: $public_dns"
    
    # 전역 변수에 저장
    INSTANCE_PUBLIC_IP="$public_ip"
    INSTANCE_PUBLIC_DNS="$public_dns"
    INSTANCE_ID="$instance_id"
}

# inventory.ini 파일 갱신 (백업 없음)
update_inventory_file() {
    local source_file="../inventory.ini"
    local target_file="../inventory.ini"
    
    log_info "inventory.ini 파일을 갱신 중..."
    
    # 원본 파일 존재 확인
    if [[ ! -f "$source_file" ]]; then
        log_error "$source_file 파일을 찾을 수 없습니다."
        exit 1
    fi
    
    # 변수 값 확인
    if [[ -z "$INSTANCE_PUBLIC_IP" ]]; then
        log_error "INSTANCE_PUBLIC_IP 변수가 비어있습니다."
        exit 1
    fi
    
    # 변경 전 내용 출력 (디버깅용)
    log_info "변경 전 inventory.ini 내용:"
    grep -n "ansible_host" "$source_file" || log_warning "ansible_host를 찾을 수 없습니다."
    
    # ansible_host 뒤의 IP 주소를 새로운 IP로 교체 (OS별 처리)
    sed_inplace "s/\(ansible_host=\)[^[:space:]]*/\1$INSTANCE_PUBLIC_IP/g" "$target_file"
    
    # 변경 후 내용 출력 (디버깅용)
    log_info "변경 후 inventory.ini 내용:"
    grep -n "ansible_host" "$target_file" || log_warning "ansible_host를 찾을 수 없습니다."
    
    log_success "inventory.ini 파일이 성공적으로 갱신되었습니다."
    log_info "  - 갱신된 ansible_host: $INSTANCE_PUBLIC_IP"
}

# docker-compose-br.yml 파일 갱신 (백업 없음)
update_docker_compose_file() {
    local source_file="../docker-container/inventory/docker-compose-br.yml"
    local target_file="$source_file"
    
    log_info "docker-compose-br.yml 파일을 갱신 중..."
    
    # 원본 파일 존재 확인
    if [[ ! -f "$source_file" ]]; then
        log_error "$source_file 파일을 찾을 수 없습니다."
        log_info "현재 디렉토리: $(pwd)"
        log_info "찾고 있는 파일: $source_file"
        exit 1
    fi
    
    log_info "파일 발견: $source_file"
    
    # 변경 전 내용 출력 (디버깅용)
    log_info "변경 전 KAFKA_ADVERTISED_LISTENERS 관련 내용:"
    grep -n "KAFKA_ADVERTISED_LISTENERS" "$source_file" || log_warning "KAFKA_ADVERTISED_LISTENERS를 찾을 수 없습니다."
    
    # KAFKA_ADVERTISED_LISTENERS에서 DNS 부분을 새 DNS로 교체 (OS별 처리)
    sed_inplace "s/ec2-[0-9-]*\.[a-z0-9-]*\.compute\.amazonaws\.com/$INSTANCE_PUBLIC_DNS/g" "$target_file"
    
    # 변경 후 내용 출력 (디버깅용)
    log_info "변경 후 KAFKA_ADVERTISED_LISTENERS 관련 내용:"
    grep -n "KAFKA_ADVERTISED_LISTENERS" "$target_file" || log_warning "KAFKA_ADVERTISED_LISTENERS를 찾을 수 없습니다."
    
    log_success "docker-compose-br.yml 파일이 성공적으로 갱신되었습니다."
    log_info "  - 파일 위치: $target_file"
    log_info "  - 갱신된 DNS: $INSTANCE_PUBLIC_DNS"
}

# 결과 확인 및 출력
verify_updates() {
    log_info "갱신 결과 확인 중..."
    
    # inventory.ini 확인
    if grep -q "ansible_host=$INSTANCE_PUBLIC_IP" inventory.ini; then
        log_success "inventory.ini - ansible_host가 올바르게 갱신되었습니다."
    else
        log_error "inventory.ini - ansible_host 갱신에 실패했습니다."
    fi
    
    # docker-compose-br.yml 확인
    local target_file="../docker-container/inventory/docker-compose-br.yml"
    if [[ -f "$target_file" ]] && grep -q "$INSTANCE_PUBLIC_DNS" "$target_file"; then
        log_success "docker-compose-br.yml - KAFKA_ADVERTISED_LISTENERS가 올바르게 갱신되었습니다."
    else
        log_error "docker-compose-br.yml - KAFKA_ADVERTISED_LISTENERS 갱신에 실패했습니다."
    fi
    
    echo
    log_info "=== 갱신 완료 요약 ==="
    log_info "인스턴스명: Docker_Compose"
    log_info "퍼블릭 IP: $INSTANCE_PUBLIC_IP"
    log_info "퍼블릭 DNS: $INSTANCE_PUBLIC_DNS"
    log_info "갱신된 파일:"
    log_info "  - ./inventory.ini"
    log_info "  - ../docker-container/inventory/docker-compose-br.yml"
}

# 사용법 출력
usage() {
    echo "사용법: $0 [인스턴스_이름]"
    echo ""
    echo "예시:"
    echo "  $0                    # 기본값 'Docker_Compose' 사용"
    echo "  $0 'My-Docker-Server' # 특정 인스턴스 이름 지정"
    echo ""
    echo "옵션:"
    echo "  -l, --list           실행 중인 모든 인스턴스 목록만 출력"
    echo "  -h, --help           이 도움말 출력"
    echo "  --region REGION      AWS 리전 지정 (기본값: ap-east-2)"
}

# 메인 실행 함수
main() {
    # 매개변수 처리
    local instance_name="Docker_Compose"  # 기본값
    local instance_name_set=false
    
    # 매개변수 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -l|--list)
                log_info "=== 실행 중인 인스턴스 목록 (리전: $AWS_REGION) ==="
                check_aws_cli
                list_running_instances
                exit 0
                ;;
            --region)
                if [[ -z "$2" ]]; then
                    log_error "--region 옵션에는 리전명이 필요합니다."
                    exit 1
                fi
                AWS_REGION="$2"
                shift 2
                ;;
            *)
                if [[ "$instance_name_set" == false ]]; then
                    instance_name="$1"
                    instance_name_set=true
                fi
                shift
                ;;
        esac
    done
    
    log_info "=== AWS 인스턴스 정보 동적 갱신 스크립트 시작 ==="
    log_info "대상 인스턴스: $instance_name"
    log_info "대상 리전: $AWS_REGION"
    log_info "운영체제: $OSTYPE"
    echo
    
    # 1. AWS CLI 확인
    check_aws_cli
    echo
    
    # 2. 인스턴스 정보 가져오기
    if ! get_instance_info "$instance_name"; then
        log_error "인스턴스를 찾을 수 없어서 스크립트를 종료합니다."
        exit 1
    fi
    echo
    
    # 3. inventory.ini 파일 갱신
    update_inventory_file
    echo
    
    # 4. docker-compose-br.yml 파일 갱신
    update_docker_compose_file
    echo
    
    # 5. 결과 확인
    verify_updates
    echo
    
    log_success "모든 작업이 성공적으로 완료되었습니다!"
}

# 스크립트 시작점
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi