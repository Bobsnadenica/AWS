#!/bin/bash
set -euo pipefail

BOLD=$(tput bold 2>/dev/null || true)
NC=$(tput sgr0 2>/dev/null || true)
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'

if ! command -v aws &>/dev/null; then
  echo -e "${RED}AWS CLI not found.${NC}"; exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
  echo -e "${RED}AWS CLI not configured properly.${NC}"; exit 1
fi

get_keyword() {
  echo -e "${BLUE}Do you need to search for a specific project/NAME keyword? (yes/no)${NC}"
  read -r yn
  yn=$(echo "$yn" | tr '[:upper:]' '[:lower:]')
  if [[ "$yn" == "yes" || "$yn" == "y" ]]; then
    while true; do
      read -rp "Enter keyword: " keyword
      [[ -n "$keyword" ]] && echo "$keyword" && return
      echo -e "${YELLOW}Keyword cannot be empty.${NC}"
    done
  else
    echo ""
  fi
}

fetch_instances() {
  local keyword="$1"
  local filters=()
  [[ -n "$keyword" ]] && filters=( --filters "Name=tag:Name,Values=*${keyword}*" )
  echo -e "\n${GREEN}Fetching EC2 instances...${NC}\n"
  aws ec2 describe-instances "${filters[@]}" \
    --query 'Reservations[].Instances[].{ID:InstanceId,Name:(Tags[?Key==`Name`].Value|[0]),State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
    --output table || { echo -e "${RED}Error fetching instances.${NC}"; exit 1; }
}

validate_results() {
  local keyword="$1"
  local filters=()
  [[ -n "$keyword" ]] && filters=( --filters "Name=tag:Name,Values=*${keyword}*" )
  result=$(aws ec2 describe-instances "${filters[@]}" --query 'Reservations[].Instances[].InstanceId' --output text || true)
  if [[ -z "${result//[[:space:]]/}" ]]; then
    [[ -n "$keyword" ]] && echo -e "${RED}No EC2 instances found matching '${keyword}'.${NC}" || echo -e "${RED}No EC2 instances found.${NC}"
    exit 0
  fi
}

echo -e "${BOLD}=== AWS EC2 Finder ===${NC}"
current_region=$(aws configure get region || echo "not-set")
echo -e "Current AWS Region: ${YELLOW}${current_region}${NC}\n"

keyword=$(get_keyword)
validate_results "$keyword"
fetch_instances "$keyword"

echo -e "\n${GREEN}Done!${NC} ✅"
