#!/bin/bash

# AWS EC2 instance IP sync script for Ansible
# Fetches active instances from Seoul region and Docker_Compose from Ohio region
# Creates ip.yml with IP variables and updates host_vars/*.yml files

ALL_YAML="group_vars/all/ip.yml"
HOST_VARS_DIR="host_vars"
TEMP_FILE=$(mktemp)

# Check AWS CLI
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        echo "ERROR: AWS CLI not found"
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "ERROR: AWS CLI not configured or no valid credentials"
        exit 1
    fi
}

# Fetch EC2 instances from Seoul region
fetch_seoul_instances() {
    echo "  Fetching Seoul region instances..." >&2
    aws ec2 describe-instances \
        --region ap-northeast-2 \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],PublicIpAddress,PrivateIpAddress,InstanceId]' \
        --output text 2>/dev/null
}

# Fetch Docker_Compose instance from Ohio region
fetch_ohio_instances() {
    echo "  Fetching Ohio region Docker_Compose instances..." >&2
    aws ec2 describe-instances \
        --region us-east-2 \
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=Docker_Compose" \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],PublicIpAddress,PrivateIpAddress,InstanceId]' \
        --output text 2>/dev/null
}

# Fetch all instances (Seoul + Ohio)
fetch_instances() {
    local seoul_instances ohio_instances all_instances
    
    seoul_instances=$(fetch_seoul_instances)
    ohio_instances=$(fetch_ohio_instances)
    
    # Combine instances
    all_instances="$seoul_instances"
    if [[ ! -z "$ohio_instances" ]]; then
        if [[ ! -z "$all_instances" ]]; then
            all_instances="$all_instances"$'\n'"$ohio_instances"
        else
            all_instances="$ohio_instances"
        fi
    fi
    
    echo "$all_instances"
}

# Generate YAML content for group_vars/all/ip.yml
generate_yaml() {
    local instances_data="$1"
    
    # Create header
    cat > "$TEMP_FILE" << 'HEADER_EOF'
---
# Auto-generated AWS EC2 instances IP addresses
# Seoul region: All running instances
# Ohio region: Docker_Compose instances
HEADER_EOF
    echo "# Generated at: $(date '+%Y-%m-%d %H:%M:%S')" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"
    
    # Add instance variables
    while IFS=$'\t' read -r name public_ip private_ip instance_id; do
        # Skip if no name tag or empty line
        [[ "$name" == "None" || -z "$name" || -z "${name// }" ]] && continue
        
        # Skip lines that look like log messages
        [[ "$name" == *"Fetching"* ]] && continue
        
        # Clean instance name for variable naming (lowercase, alphanumeric + underscore)
        local var_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_' | sed 's/^[0-9]/_&/')
        
        # Skip if variable name is empty after cleaning
        [[ -z "$var_name" ]] && continue
        
        # Handle missing IPs
        [[ "$public_ip" == "None" ]] && public_ip=""
        [[ "$private_ip" == "None" ]] && private_ip=""
        
        # Append to file
        echo "${var_name}_public_ip: \"${public_ip}\"" >> "$TEMP_FILE"
        echo "${var_name}_private_ip: \"${private_ip}\"" >> "$TEMP_FILE"
    done <<< "$instances_data"
}

# Get node_id for specific instances
get_node_id() {
    local instance_name="$1"
    
    case "$instance_name" in
        "CP1_Broker1_A") echo "1" ;;
        "CP1_Broker2_A") echo "2" ;;
        "CP1_Broker3_A") echo "3" ;;
        "CP1_Controller1_A") echo "101" ;;
        "CP1_Controller2_A") echo "102" ;;
        "CP1_Controller3_A") echo "103" ;;
        *) echo "" ;;
    esac
}

# Update host_vars YAML files
update_host_vars() {
    local instances_data="$1"
    local updated_count=0
    local created_count=0
    
    # Create host_vars directory if it doesn't exist
    if [[ ! -d "$HOST_VARS_DIR" ]]; then
        echo "Creating $HOST_VARS_DIR directory..."
        mkdir -p "$HOST_VARS_DIR"
    fi
    
    echo "Processing host_vars files..."
    
    # Process each running instance
    while IFS=$'\t' read -r name public_ip private_ip instance_id; do
        # Skip if no name tag
        [[ "$name" == "None" || -z "$name" ]] && continue
        [[ "$public_ip" == "None" ]] && public_ip=""
        
        echo "  Processing instance: '$name'"
        
        # Look for existing file with this server_name
        local existing_file=""
        local found_in_file=false
        
        # Check all existing yml/yaml files
        for yaml_file in "$HOST_VARS_DIR"/*.yml "$HOST_VARS_DIR"/*.yaml; do
            [[ ! -f "$yaml_file" ]] && continue
            
            # Extract server_name from file
            local file_server_name=""
            if grep -q "^server_name:" "$yaml_file"; then
                file_server_name=$(grep "^server_name:" "$yaml_file" | sed 's/^server_name:[[:space:]]*//; s/^"//; s/"$//' | xargs)
            fi
            
            # Check if this file is for our instance
            if [[ "$file_server_name" == "$name" ]]; then
                existing_file="$yaml_file"
                found_in_file=true
                echo "    Found existing file: $(basename "$yaml_file")"
                break
            fi
        done
        
        if [[ "$found_in_file" == true ]]; then
            # Update existing file
            local current_ip=""
            local current_node_id=""
            if grep -q "^public_ip:" "$existing_file"; then
                current_ip=$(grep "^public_ip:" "$existing_file" | sed 's/^public_ip:[[:space:]]*//; s/^"//; s/"$//' | xargs)
            fi
            if grep -q "^node_id:" "$existing_file"; then
                current_node_id=$(grep "^node_id:" "$existing_file" | sed 's/^node_id:[[:space:]]*//; s/^"//; s/"$//' | xargs)
            fi
            
            # Get required node_id for this instance
            local required_node_id
            required_node_id=$(get_node_id "$name")
            
            echo "    Current IP: '$current_ip' -> New IP: '$public_ip'"
            if [[ -n "$required_node_id" ]]; then
                echo "    Current node_id: '$current_node_id' -> Required node_id: '$required_node_id'"
            fi
            
            # Check if update is needed
            local needs_update=false
            if [[ "$current_ip" != "$public_ip" ]]; then
                needs_update=true
            fi
            if [[ -n "$required_node_id" && "$current_node_id" != "$required_node_id" ]]; then
                needs_update=true
            fi
            
            if [[ "$needs_update" == true ]]; then
                # Create temporary file for update
                local temp_file=$(mktemp)
                local public_ip_found=false
                local node_id_found=false
                
                # First pass: check what exists
                while IFS= read -r line; do
                    if [[ "$line" =~ ^public_ip: ]]; then
                        public_ip_found=true
                    elif [[ "$line" =~ ^node_id: ]]; then
                        node_id_found=true
                    fi
                done < "$existing_file"
                
                # Second pass: update the file
                while IFS= read -r line; do
                    if [[ "$line" =~ ^public_ip: ]]; then
                        echo "public_ip: \"$public_ip\""
                    elif [[ "$line" =~ ^node_id: ]] && [[ -n "$required_node_id" ]]; then
                        echo "node_id: $required_node_id"
                    else
                        echo "$line"
                        # Add public_ip after server_name if it doesn't exist
                        if [[ "$line" =~ ^server_name: ]] && [[ "$public_ip_found" == false ]]; then
                            echo "public_ip: \"$public_ip\""
                            public_ip_found=true
                        fi
                    fi
                done < "$existing_file" > "$temp_file"
                
                # Add node_id at the end if required and not found
                if [[ -n "$required_node_id" ]] && [[ "$node_id_found" == false ]]; then
                    echo "node_id: $required_node_id" >> "$temp_file"
                fi
                
                # Replace original file
                if mv "$temp_file" "$existing_file"; then
                    echo "    ✓ Updated $(basename "$existing_file")"
                    ((updated_count++))
                else
                    echo "    ✗ Failed to update $(basename "$existing_file")"
                    rm -f "$temp_file"
                fi
            else
                echo "    No update needed"
            fi
        else
            # Create new file - 원본 인스턴스 이름으로 파일명 생성 (대소문자 유지)
            local new_file="$HOST_VARS_DIR/${name}.yml"
            echo "    Creating new file: $(basename "$new_file")"
            
            # Get node_id for this instance if applicable
            local node_id
            node_id=$(get_node_id "$name")
            
            # Make sure we don't overwrite existing files with different server_name
            local counter=1
            while [[ -f "$new_file" ]]; do
                # Check if existing file has different server_name
                local existing_server_name=""
                if grep -q "^server_name:" "$new_file"; then
                    existing_server_name=$(grep "^server_name:" "$new_file" | sed 's/^server_name:[[:space:]]*//; s/^"//; s/"$//' | xargs)
                fi
                
                if [[ "$existing_server_name" == "$name" ]]; then
                    # Same server_name, this shouldn't happen but handle it
                    echo "    Found duplicate file with same server_name: $(basename "$new_file")"
                    break
                else
                    # Different server_name, try new filename with counter
                    new_file="$HOST_VARS_DIR/${name}_${counter}.yml"
                    ((counter++))
                fi
            done
            
            # Create the file content
            {
                echo "---"
                echo "# Auto-generated host variables for $name"
                echo "# Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
                echo "# controller를 위해서 aws_access_key_id와 aws_secret_access_key를 추가해주세요"
                echo ""
                echo "server_name: \"$name\""
                echo "public_ip: \"$public_ip\""
                
                # Add node_id if this instance requires it
                if [[ -n "$node_id" ]]; then
                    echo "node_id: $node_id"
                fi
            } > "$new_file"
            
            if [[ $? -eq 0 ]]; then
                echo "    ✓ Created new file: $(basename "$new_file")"
                if [[ -n "$node_id" ]]; then
                    echo "      Added node_id: $node_id"
                fi
                ((created_count++))
            else
                echo "    ✗ Failed to create $(basename "$new_file")"
            fi
        fi
        
    done <<< "$instances_data"
    
    echo ""
    echo "Host vars summary:"
    echo "  - Updated files: $updated_count"
    echo "  - Created files: $created_count"
    echo ""
}

# Main execution
main() {
    echo "=== AWS EC2 IP Synchronization Script ==="
    echo ""
    
    echo "Checking AWS CLI configuration..."
    check_aws_cli
    
    echo "Fetching running EC2 instances..."
    local instances_data
    instances_data=$(fetch_instances)
    
    if [[ -z "$instances_data" ]]; then
        echo "No running instances found"
        exit 1
    fi
    
    local instance_count
    instance_count=$(echo "$instances_data" | grep -v "^None" | wc -l | tr -d ' ')
    echo "Found $instance_count running instances with Name tags"
    echo ""
    
    # Show found instances by region
    echo "Found instances:"
    local count=0
    local seoul_count=0
    local ohio_count=0
    
    while IFS=$'\t' read -r name public_ip private_ip instance_id; do
        [[ "$name" == "None" || -z "$name" ]] && continue
        ((count++))
        
        # Determine region based on instance name pattern
        if [[ "$name" == "Docker_Compose" ]]; then
            echo "  $count. $name (Ohio) - Public: ${public_ip:-N/A}, Private: ${private_ip:-N/A}"
            ((ohio_count++))
        else
            echo "  $count. $name (Seoul) - Public: ${public_ip:-N/A}, Private: ${private_ip:-N/A}"
            ((seoul_count++))
        fi
    done <<< "$instances_data"
    
    echo ""
    echo "Region summary:"
    echo "  - Seoul region: $seoul_count instances"
    echo "  - Ohio region: $ohio_count instances"
    echo ""
    
    echo "=== Updating group_vars/all/ip.yml ==="
    
    # Ensure group_vars directory exists
    if [[ ! -d "group_vars/all" ]]; then
        echo "Creating group_vars/all directory..."
        mkdir -p "group_vars/all"
    fi
    
    generate_yaml "$instances_data"
    
    # Move temp file to final location
    if mv "$TEMP_FILE" "$ALL_YAML"; then
        echo "✓ Successfully created/updated $ALL_YAML"
        
        # Show summary of variables created
        local var_count
        var_count=$(grep -c "_ip:" "$ALL_YAML" 2>/dev/null || echo "0")
        echo "  Created $var_count IP variables"
    else
        echo "✗ ERROR: Failed to create $ALL_YAML"
        rm -f "$TEMP_FILE"
        exit 1
    fi
    echo ""
    
    echo "=== Updating host_vars files ==="
    update_host_vars "$instances_data"
    
    echo "✓ IP synchronization completed successfully!"
    echo ""
    
    # Show final summary
    echo "Summary:"
    echo "  - group_vars/all/ip.yml: Updated with $(grep -c "_ip:" "$ALL_YAML" 2>/dev/null || echo "0") variables"
    echo "  - host_vars/: Processed $instance_count instances ($seoul_count Seoul + $ohio_count Ohio)"
    echo ""
}

# Cleanup on exit
trap 'rm -f "$TEMP_FILE" 2>/dev/null' EXIT

# Run main function
main "$@"