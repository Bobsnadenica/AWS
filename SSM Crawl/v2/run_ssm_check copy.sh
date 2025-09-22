#!/bin/bash
set -euo pipefail

# ==============================
# Colors & Script Info
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# ==============================
# Output Files
# ==============================
timestamp=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="aws_doctor_report_${timestamp}.md"
echo -e "# AWS Doctor Report - ${timestamp}\n" > "$OUTPUT_FILE"

# ==============================
# CLI Arguments
# ==============================
PROFILE_ARG=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile) PROFILE_ARG="--profile $2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) echo "Usage: $0 [-p profile] [-d dry-run]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ==============================
# Load External Scripts
# ==============================
LINUX_SCRIPT="$SCRIPT_DIR/get_linux_info.sh"
WINDOWS_SCRIPT="$SCRIPT_DIR/get_windows_info.ps1"

if [[ ! -f "$LINUX_SCRIPT" || ! -f "$WINDOWS_SCRIPT" ]]; then
    echo -e "${RED}ERROR: Missing command scripts.${NC}"; exit 1
fi
LINUX_COMMAND=$(cat "$LINUX_SCRIPT")
WINDOWS_COMMAND=$(cat "$WINDOWS_SCRIPT")

# ==============================
# Helper Functions
# ==============================
log() { echo -e "$1" | tee -a "$OUTPUT_FILE"; }
prompt_yes_no() { read -p "$1 [y/n]: " -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]]; }

# ------------------------------
# Fetch EC2 Instances
# ------------------------------
fetch_instances() {
    log "${BLUE}Fetching EC2 instances...${NC}"
    aws ec2 describe-instances $PROFILE_ARG \
        --query 'Reservations[].Instances[].[InstanceId, State.Name, PlatformDetails, Tags[?Key==`Name`].Value | [0], InstanceType, ImageId, PublicIpAddress, PrivateIpAddress, SecurityGroups[*].GroupName|join(`, `), SubnetId]' \
        --output json
}

# ------------------------------
# Run SSM Command
# ------------------------------
run_ssm_command() {
    local instance_id="$1"
    local os_type="$2"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}[DRY-RUN] Would run SSM on $instance_id ($os_type)${NC}"
        return
    fi
    local doc_name commands_param
    if [[ "$os_type" == "Windows" ]]; then
        doc_name="AWS-RunPowerShellScript"
        commands_param="{\"commands\":[$WINDOWS_COMMAND]}"
    else
        doc_name="AWS-RunShellScript"
        commands_param="{\"commands\":[\"$LINUX_COMMAND\"]}"
    fi
    cmd_id=$(aws ssm send-command $PROFILE_ARG \
        --instance-ids "$instance_id" \
        --document-name "$doc_name" \
        --parameters "$commands_param" \
        --query "Command.CommandId" --output text)
    log "${BLUE}Waiting for SSM command $cmd_id on $instance_id...${NC}"
    aws ssm wait command-executed $PROFILE_ARG --command-id "$cmd_id" --instance-id "$instance_id"
    output=$(aws ssm get-command-invocation $PROFILE_ARG --command-id "$cmd_id" --instance-id "$instance_id" --output text)
    log "### SSM Output for $instance_id ($os_type)"
    log '```'
    log "$output"
    log '```'
}

# ------------------------------
# Inspect Volumes
# ------------------------------
inspect_volumes() {
    log "${BLUE}Listing EC2 Volumes...${NC}"
    aws ec2 describe-volumes $PROFILE_ARG --output table | tee -a "$OUTPUT_FILE"
}

# ------------------------------
# Inspect Security Groups
# ------------------------------
inspect_security_groups() {
    log "${BLUE}Listing Security Groups...${NC}"
    aws ec2 describe-security-groups $PROFILE_ARG --output table | tee -a "$OUTPUT_FILE"
}

# ------------------------------
# Check for missing tags
# ------------------------------
check_tags() {
    read -p "Enter required tag key (e.g., Name, Environment): " tag_key
    log "${BLUE}Checking EC2 instances missing tag '$tag_key'...${NC}"
    aws ec2 describe-instances $PROFILE_ARG \
        --query "Reservations[].Instances[?!(Tags[?Key=='$tag_key'])].[InstanceId, State.Name, Tags]" \
        --output table | tee -a "$OUTPUT_FILE"
}

# ------------------------------
# Search Resources by Tag
# ------------------------------
search_by_tag() {
    read -p "Enter tag key: " key
    read -p "Enter tag value: " value
    log "${BLUE}Searching EC2 instances with $key=$value...${NC}"
    aws ec2 describe-instances $PROFILE_ARG --filters "Name=tag:$key,Values=$value" \
        --query 'Reservations[].Instances[].[InstanceId, State.Name, Tags[?Key==`Name`].Value|[0]]' \
        --output table | tee -a "$OUTPUT_FILE"
    log "${BLUE}Searching Volumes with $key=$value...${NC}"
    aws ec2 describe-volumes $PROFILE_ARG --filters "Name=tag:$key,Values=$value" \
        --query 'Volumes[*].[VolumeId,Size,State,Attachments[*].InstanceId|join(`, `)]' \
        --output table | tee -a "$OUTPUT_FILE"
}

# ==============================
# Interactive Menu
# ==============================
while true; do
    echo -e "\n${BLUE}=== AWS Doctor Menu ===${NC}"
    echo "1) List all EC2 instances"
    echo "2) Run SSM commands on instances"
    echo "3) Inspect volumes"
    echo "4) Inspect security groups"
    echo "5) Check missing tags on instances"
    echo "6) Search resources by tag"
    echo "7) Exit"
    read -p "Select an option [1-7]: " choice

    case $choice in
        1)
            instances_json=$(fetch_instances)
            echo "$instances_json" | jq -r '.[] | @tsv' | column -t
            ;;
        2)
            instances_json=$(fetch_instances)
            for inst in $(echo "$instances_json" | jq -r '.[] | @base64'); do
                _jq() { echo "$inst" | base64 --decode | jq -r "$1"; }
                id=$(_jq '.[0]'); state=$(_jq '.[1]'); platform=$(_jq '.[2]')
                [[ "$state" != "running" ]] && log "${YELLOW}[SKIP] $id is $state${NC}" && continue
                os_type="Linux"; [[ "$platform" == "windows" ]] && os_type="Windows"
                run_ssm_command "$id" "$os_type"
            done
            ;;
        3) inspect_volumes ;;
        4) inspect_security_groups ;;
        5) check_tags ;;
        6) search_by_tag ;;
        7) log "${GREEN}Exiting AWS Doctor.${NC}"; exit 0 ;;
        *) echo "Invalid option, choose 1-7." ;;
    esac
done
