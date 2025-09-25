#!/bin/bash

# Exit on errors
set -euo pipefail

# ==============================
# Colors
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================
# Functions
# ==============================
prompt_project_filter() {
    echo -e "${BLUE}Do you need to search for a specific project keyword? (yes/no)${NC}"
    read -r answer
    if [[ "$answer" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        echo -e "${YELLOW}Enter the keyword (e.g., 'test', 'prod', etc.):${NC}"
        read -r keyword
    else
        keyword=""
    fi
}

get_ec2_instances() {
    echo -e "${GREEN}Fetching EC2 instance list...${NC}"
    
    if [[ -n "$keyword" ]]; then
        echo -e "${BLUE}Filtering EC2 instances by keyword: '${keyword}'${NC}"
        filter="--filters Name=tag:Name,Values=*${keyword}*"
    else
        filter=""
    fi

    # Run AWS CLI to get EC2 data
    aws ec2 describe-instances $filter \
        --query "Reservations[].Instances[].[InstanceId, State.Name, InstanceType, Placement.AvailabilityZone, Tags[?Key=='Name'].Value|[0]]" \
        --output table
}

# ==============================
# Main
# ==============================
echo -e "${YELLOW}=== EC2 Finder Script ===${NC}"
prompt_project_filter
get_ec2_instances

echo -e "\n${GREEN}Done!${NC}"
