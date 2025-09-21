#!/bin/bash

# Exit on any error, treat unset variables as an error, and propagate pipeline failures.
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
# Usage Function
# ==============================
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Runs SSM commands to gather information from EC2 instances."
  echo
  echo "Options:"
  echo "  -p, --profile PROFILE   Specify the AWS CLI profile to use."
  echo "  -l, --linux-only        Run on Linux instances only."
  echo "  -w, --windows-only      Run on Windows instances only."
  echo "  -d, --dry-run           Print commands instead of executing them."
  echo "  -h, --help              Display this help message."
}

# ==============================
# CLI Argument Parsing with getopts
# ==============================
PROFILE_ARG=""
MODE="all"
DRY_RUN=0

# Note: getopts doesn't support long options natively.
# We handle them by mapping in the case statement.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      if [[ -z "${2:-}" ]]; then echo "ERROR: Profile name is missing." >&2; exit 1; fi
      PROFILE_ARG="--profile $2"
      shift 2
      ;;
    -l|--linux-only)
      MODE="linux"
      shift
      ;;
    -w|--windows-only)
      MODE="windows"
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# ==============================
# Load External Command Scripts
# ==============================
LINUX_COMMAND_FILE="$SCRIPT_DIR/get_linux_info.sh"
POWERSHELL_COMMAND_FILE="$SCRIPT_DIR/get_windows_info.ps1"

if [[ ! -f "$LINUX_COMMAND_FILE" || ! -f "$POWERSHELL_COMMAND_FILE" ]]; then
    echo -e "${RED}ERROR: Missing command script files. Ensure get_linux_info.sh and get_windows_info.ps1 are in the same directory.${NC}" >&2
    exit 1
fi

LINUX_COMMAND=$(cat "$LINUX_COMMAND_FILE")
POWERSHELL_COMMAND=$(cat "$POWERSHELL_COMMAND_FILE")

# ==============================
# Setup Output Files
# ==============================
timestamp=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="ssm_report_${timestamp}.md"
CSV_FILE="ssm_report_${timestamp}.csv"
XLSX_FILE="ssm_report_${timestamp}.xlsx"

# Initialize counters and timers
success_count=0
fail_count=0
skipped_count=0
instance_number=0
start_time=$(date +%s)

# ==============================
# Get All Instances
# ==============================
echo -e "${BLUE}Fetching list of all EC2 instances...${NC}"
instances_json=$(aws ec2 describe-instances $PROFILE_ARG \
  --query 'Reservations[].Instances[].[InstanceId, State.Name, PlatformDetails, Tags[?Key==`Name`].Value | [0]]' \
  --output json)

if [[ -z "$instances_json" ]]; then
  echo -e "${RED}ERROR: Could not retrieve EC2 instances. Check your AWS credentials and profile name.${NC}" >&2
  exit 1
fi
total_instances=$(echo "$instances_json" | jq 'length')
echo "Found $total_instances instances to process."

# ==============================
# Main Processing Loop
# ==============================
jq -c '.[]' <<< "$instances_json" | while read -r instance_details; do
  ((instance_number++))
  
  INSTANCE_ID=$(jq -r '.[0]' <<<"$instance_details")
  INSTANCE_STATE=$(jq -r '.[1]' <<<"$instance_details")
  PLATFORM=$(jq -r '.[2]' <<<"$instance_details")
  INSTANCE_NAME=$(jq -r '.[3] // "N/A"' <<<"$instance_details")

  # Use printf for better formatting control
  printf "\n%s\n" "================================================================================" | tee -a "$OUTPUT_FILE"
  printf "INSTANCE #%d: %s (%s) [%d/%d]\n" "$instance_number" "$INSTANCE_ID" "$INSTANCE_NAME" "$instance_number" "$total_instances" | tee -a "$OUTPUT_FILE"

  # --- Filtering Logic ---
  if [[ "$INSTANCE_STATE" != "running" ]]; then
    echo -e "${YELLOW}[SKIP] Instance is not running (state: $INSTANCE_STATE).${NC}" | tee -a "$OUTPUT_FILE"
    ((skipped_count++))
    continue
  fi

  if [[ "$PLATFORM" == "windows" ]]; then
    OS_TYPE="Windows"
    [[ "$MODE" == "linux" ]] && { echo -e "${YELLOW}[SKIP] Skipping Windows instance due to --linux-only flag.${NC}" | tee -a "$OUTPUT_FILE"; ((skipped_count++)); continue; }
  else # Default to Linux for "Linux/UNIX" or null platforms
    OS_TYPE="Linux"
    [[ "$MODE" == "windows" ]] && { echo -e "${YELLOW}[SKIP] Skipping Linux instance due to --windows-only flag.${NC}" | tee -a "$OUTPUT_FILE"; ((skipped_count++)); continue; }
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}[DRY-RUN] Would run SSM command for $OS_TYPE on $INSTANCE_ID.${NC}" | tee -a "$OUTPUT_FILE"
    # Write placeholder to file for parser
    echo -e "\n[Dry-run mode: command not executed]\n" >> "$OUTPUT_FILE"
    ((success_count++)) # Count dry runs as "success" for the purpose of the summary
    continue
  fi

  # --- Send SSM Command ---
  echo "Sending SSM command to $INSTANCE_ID ($OS_TYPE)..."
  if [[ "$OS_TYPE" == "Windows" ]]; then
    DOCUMENT_NAME="AWS-RunPowerShellScript"
    COMMANDS_PARAM="{\"commands\":[$POWERSHELL_COMMAND]}"
  else
    DOCUMENT_NAME="AWS-RunShellScript"
    COMMANDS_PARAM="{\"commands\":[\"$LINUX_COMMAND\"]}"
  fi
  
  CMD_ID=$(aws ssm send-command $PROFILE_ARG \
    --instance-ids "$INSTANCE_ID" \
    --document-name "$DOCUMENT_NAME" \
    --parameters "$COMMANDS_PARAM" \
    --query "Command.CommandId" --output text 2> >(tee /dev/stderr))
  
  if [[ -z "$CMD_ID" ]]; then
    echo -e "${RED}[ERROR] Failed to send SSM command to $INSTANCE_ID.${NC}" | tee -a "$OUTPUT_FILE"
    echo -e "\n[ERROR: Could not send SSM command]\n" >> "$OUTPUT_FILE"
    ((fail_count++))
    continue
  fi
  
  # --- Wait for Command to Finish (The Efficient Way) ---
  echo -e "${BLUE}Waiting for command $CMD_ID to complete on $INSTANCE_ID...${NC}"
  if ! aws ssm wait command-executed $PROFILE_ARG --command-id "$CMD_ID" --instance-id "$INSTANCE_ID"; then
    echo -e "${RED}[ERROR] Command $CMD_ID failed or timed out on $INSTANCE_ID.${NC}" | tee -a "$OUTPUT_FILE"
    echo -e "\n[ERROR: SSM command failed or timed out]\n" >> "$OUTPUT_FILE"
    ((fail_count++))
    continue
  fi

  # --- Get Command Output ---
  echo -e "${GREEN}Command completed successfully. Fetching output...${NC}"
  OUTPUT=$(aws ssm get-command-invocation $PROFILE_ARG \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" \
    --output text)

  echo "### SSM Output" | tee -a "$OUTPUT_FILE"
  echo '```json' | tee -a "$OUTPUT_FILE"
  echo "$OUTPUT" | tee -a "$OUTPUT_FILE"
  echo '```' | tee -a "$OUTPUT_FILE"
  ((success_count++))

done

# ==============================
# Summary
# ==============================
end_time=$(date +%s)
elapsed=$((end_time - start_time))
total_processed=$((success_count + fail_count))
success_rate=0
if (( total_processed > 0 )); then
    success_rate=$(( (success_count * 100) / total_processed ))
fi

echo -e "\n================================================================================"
echo -e "${BLUE}Run complete. Final Summary:${NC}"
echo -e "  - ${GREEN}Successful Commands: $success_count${NC}"
echo -e "  - ${RED}Failed Commands:     $fail_count${NC}"
echo -e "  - ${YELLOW}Skipped Instances:   $skipped_count${NC}"
echo -e "  - Total Instances:     $total_instances"
echo -e "  - Duration:            ${elapsed}s"
echo -e "  - Success Rate:        ${success_rate}%"
echo -e "--------------------------------------------------------------------------------"
echo -e "${BLUE}Generating reports...${NC}"
echo -e "  - Raw Markdown Log: $OUTPUT_FILE"

# ==============================
# Generate CSV/XLSX Reports
# ==============================
if (( total_processed > 0 )); then
    # Check if pandas is available, prompt to install if not.
    if ! python3 -c "import pandas" &>/dev/null; then
        echo -e "${YELLOW}Python 'pandas' library not found. It is required for CSV/Excel reports.${NC}"
        read -p "Attempt to install it now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            python3 -m pip install pandas openpyxl
        else
            echo "Skipping report generation."
            exit 0
        fi
    fi
    python3 "$SCRIPT_DIR/report_parser.py" "$OUTPUT_FILE" "$CSV_FILE" "$XLSX_FILE"
else
    echo "No commands were executed, skipping report generation."
fi