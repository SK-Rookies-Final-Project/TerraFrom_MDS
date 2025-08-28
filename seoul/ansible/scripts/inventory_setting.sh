#!/bin/bash

# Ansible inventory.ini 동적 생성 스크립트
# AWS CLI를 사용하여 모든 실행 중인 인스턴스의 퍼블릭 IP를 조회하고 이름 기반으로 분류합니다.

INVENTORY_FILE="inventory.ini"

echo "AWS에서 실행 중인 모든 EC2 인스턴스를 조회하고 있습니다..."

# 모든 실행 중인 EC2 인스턴스의 이름과 퍼블릭 IP 조회
instances_info=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value|[0],PublicIpAddress]" \
    --output text)

if [ -z "$instances_info" ]; then
    echo "실행 중인 인스턴스를 찾을 수 없습니다."
    echo "다음 명령어로 확인해보세요: aws ec2 describe-instances --filters \"Name=instance-state-name,Values=running\""
    exit 1
fi

# 각 그룹별 배열 선언
declare -a brokers
declare -a controllers
declare -a schema_registries
declare -a connect_workers
declare -a control_centers
declare -a others

# 인스턴스 정보를 이름 기준으로 정렬한 후 분류
sorted_instances=$(echo "$instances_info" | sort -k1,1)

while IFS=$'\t' read -r name ip; do
    # None이나 빈 값 처리
    if [ "$name" = "None" ] || [ -z "$name" ]; then
        name="unnamed-instance-$RANDOM"
    fi
    if [ "$ip" = "None" ] || [ -z "$ip" ]; then
        echo "경고: $name 인스턴스에 퍼블릭 IP가 없습니다. 건너뜁니다."
        continue
    fi
    
    # 이름을 소문자로 변환하여 패턴 매칭
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    entry="$name ansible_host=$ip"
    
    # 이름 패턴에 따라 분류
    if [[ $name_lower == *"broker"* ]]; then
        brokers+=("$entry")
    elif [[ $name_lower == *"controller"* ]]; then
        controllers+=("$entry")
    elif [[ $name_lower == *"sr"* ]] || [[ $name_lower == *"schema"* ]] || [[ $name_lower == *"registry"* ]]; then
        schema_registries+=("$entry")
    elif [[ $name_lower == *"connect"* ]]; then
        connect_workers+=("$entry")
    elif [[ $name_lower == *"c3"* ]] || [[ $name_lower == *"control"* ]] || [[ $name_lower == *"center"* ]]; then
        control_centers+=("$entry")
    else
        others+=("$entry")
    fi
done <<< "$sorted_instances"

echo "분류 결과:"
echo "  Brokers: ${#brokers[@]}"
echo "  Controllers: ${#controllers[@]}"
echo "  Schema Registries: ${#schema_registries[@]}"
echo "  Connect Workers: ${#connect_workers[@]}"
echo "  Control Centers: ${#control_centers[@]}"
echo "  Others: ${#others[@]}"

# 각 그룹 내에서도 이름으로 정렬하는 함수 (호환성 개선)
sort_group() {
    local group_name="$1"
    local temp_file=$(mktemp)
    
    # 배열 이름에 따라 분기 처리
    case "$group_name" in
        "brokers")
            if [ ${#brokers[@]} -gt 0 ]; then
                printf '%s\n' "${brokers[@]}" | sort > "$temp_file"
                brokers=()
                while IFS= read -r line; do
                    brokers+=("$line")
                done < "$temp_file"
            fi
            ;;
        "controllers")
            if [ ${#controllers[@]} -gt 0 ]; then
                printf '%s\n' "${controllers[@]}" | sort > "$temp_file"
                controllers=()
                while IFS= read -r line; do
                    controllers+=("$line")
                done < "$temp_file"
            fi
            ;;
        "schema_registries")
            if [ ${#schema_registries[@]} -gt 0 ]; then
                printf '%s\n' "${schema_registries[@]}" | sort > "$temp_file"
                schema_registries=()
                while IFS= read -r line; do
                    schema_registries+=("$line")
                done < "$temp_file"
            fi
            ;;
        "connect_workers")
            if [ ${#connect_workers[@]} -gt 0 ]; then
                printf '%s\n' "${connect_workers[@]}" | sort > "$temp_file"
                connect_workers=()
                while IFS= read -r line; do
                    connect_workers+=("$line")
                done < "$temp_file"
            fi
            ;;
        "control_centers")
            if [ ${#control_centers[@]} -gt 0 ]; then
                printf '%s\n' "${control_centers[@]}" | sort > "$temp_file"
                control_centers=()
                while IFS= read -r line; do
                    control_centers+=("$line")
                done < "$temp_file"
            fi
            ;;
        "others")
            if [ ${#others[@]} -gt 0 ]; then
                printf '%s\n' "${others[@]}" | sort > "$temp_file"
                others=()
                while IFS= read -r line; do
                    others+=("$line")
                done < "$temp_file"
            fi
            ;;
    esac
    
    rm -f "$temp_file"
}

# 각 그룹 내에서 정렬
sort_group "brokers"
sort_group "controllers"
sort_group "schema_registries"
sort_group "connect_workers"
sort_group "control_centers"
sort_group "others"

# inventory.ini 파일 생성 시작
cat > $INVENTORY_FILE << 'EOL'
[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/Desktop/ct/common/test-key.pem
ansible_become=yes

EOL

# Brokers
echo "[brokers]" >> $INVENTORY_FILE
if [ ${#brokers[@]} -gt 0 ]; then
    printf '%s\n' "${brokers[@]}" >> $INVENTORY_FILE
else
    echo "# broker 인스턴스를 찾을 수 없습니다" >> $INVENTORY_FILE
fi
echo "" >> $INVENTORY_FILE

# Controllers
echo "[controllers]" >> $INVENTORY_FILE
if [ ${#controllers[@]} -gt 0 ]; then
    printf '%s\n' "${controllers[@]}" >> $INVENTORY_FILE
else
    echo "# controller 인스턴스를 찾을 수 없습니다" >> $INVENTORY_FILE
fi
echo "" >> $INVENTORY_FILE

# Schema Registries
echo "[schema_registries]" >> $INVENTORY_FILE
if [ ${#schema_registries[@]} -gt 0 ]; then
    printf '%s\n' "${schema_registries[@]}" >> $INVENTORY_FILE
else
    echo "# schema_registry 인스턴스를 찾을 수 없습니다" >> $INVENTORY_FILE
fi
echo "" >> $INVENTORY_FILE

# Connect Workers
echo "[connect_workers]" >> $INVENTORY_FILE
if [ ${#connect_workers[@]} -gt 0 ]; then
    printf '%s\n' "${connect_workers[@]}" >> $INVENTORY_FILE
else
    echo "# connect_worker 인스턴스를 찾을 수 없습니다" >> $INVENTORY_FILE
fi
echo "" >> $INVENTORY_FILE

# Control Center
echo "[control_center]" >> $INVENTORY_FILE
if [ ${#control_centers[@]} -gt 0 ]; then
    printf '%s\n' "${control_centers[@]}" >> $INVENTORY_FILE
else
    echo "# control_center 인스턴스를 찾을 수 없습니다" >> $INVENTORY_FILE
fi
echo "" >> $INVENTORY_FILE

# 분류되지 않은 인스턴스들
if [ ${#others[@]} -gt 0 ]; then
    echo "[others]" >> $INVENTORY_FILE
    echo "# 분류되지 않은 인스턴스들:" >> $INVENTORY_FILE
    printf '%s\n' "${others[@]}" >> $INVENTORY_FILE
    echo "" >> $INVENTORY_FILE
fi

total_classified=$((${#brokers[@]} + ${#controllers[@]} + ${#schema_registries[@]} + ${#connect_workers[@]} + ${#control_centers[@]}))

echo "inventory.ini 파일이 생성되었습니다."
echo "===================="
echo "분류된 인스턴스 수: $total_classified"
echo "분류되지 않은 인스턴스 수: ${#others[@]}"
echo "===================="
echo "생성된 파일 내용:"
echo "===================="
cat $INVENTORY_FILE