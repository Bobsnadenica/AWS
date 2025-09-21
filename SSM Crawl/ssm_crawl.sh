#!/bin/bash

# ==============================
# Colors for terminal output
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ==============================
# CLI arguments
# ==============================
PROFILE=""
MODE="all"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-only) MODE="linux" ;;
    --windows-only) MODE="windows" ;;
    --all) MODE="all" ;;
    --profile) PROFILE="--profile $2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "Usage: $0 [--linux-only | --windows-only | --all] [--profile PROFILE] [--dry-run]"; exit 1 ;;
  esac
  shift
done

# ==============================
# Output files with timestamp
# ==============================
timestamp=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="ssm_report_${timestamp}.md"
CSV_FILE="ssm_report_${timestamp}.csv"
XLSX_FILE="ssm_report_${timestamp}.xlsx"

success_count=0
fail_count=0
instance_number=1
start_time=$(date +%s)

# ==============================
# Get all instances
# ==============================
instances_json=$(aws ec2 describe-instances $PROFILE \
  --query 'Reservations[].Instances[].[InstanceId, State.Name, PlatformDetails, Tags]' \
  --output json 2>/dev/null)

if [[ $? -ne 0 || -z "$instances_json" ]]; then
  echo -e "${RED}ERROR: Could not retrieve EC2 instances.${NC}"
  exit 1
fi

# ==============================
# PowerShell command for Windows
# ==============================
read -r -d '' POWERSHELL_COMMAND <<'EOF'
[
  "Write-Output '---BEGIN OUTPUT---'",
  "$uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime",
  "Write-Output (\"Uptime: {0:%d} days, {0:%h} hrs, {0:%m} mins\" -f $uptime)",
  "$falconSvc = Get-Service -Name 'CSFalconService' -ErrorAction SilentlyContinue",
  "if ($null -eq $falconSvc) { Write-Output 'Falcon Service: Not installed' } elseif ($falconSvc.Status -eq 'Running') { Write-Output 'Falcon Service: Running' } else { Write-Output 'Falcon Service: Not running' }",
  "Write-Output 'Pending Updates:'",
  "$session = New-Object -ComObject Microsoft.Update.Session -ErrorAction SilentlyContinue",
  "if ($session -ne $null) { $searcher = $session.CreateUpdateSearcher(); $results = $searcher.Search(\"IsInstalled=0 and Type='Software'\").Updates; $max = if ($results.Count -lt 3) { $results.Count } else { 3 }; for ($i = 0; $i -lt $max; $i++) { Write-Output \"- $($results.Item($i).Title)\" }; if ($results.Count -eq 0) { Write-Output '- None' } } else { Write-Output 'Update service unavailable' }",
  "Write-Output '---END OUTPUT---'"
]
EOF

# ==============================
# Function: run_ssm_command
# ==============================
run_ssm_command() {
  local instance_id=$1
  local os_type=$2

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] Would send SSM command to $instance_id ($os_type)"
    return 0
  fi

  local cmd_id
  if [[ "$os_type" == "Windows" ]]; then
    cmd_id=$(aws ssm send-command $PROFILE \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunPowerShellScript" \
      --parameters commands="$POWERSHELL_COMMAND" \
      --comment "Windows: Uptime, Falcon, Updates" \
      --query "Command.CommandId" --output text 2>&1)
  else
    cmd_id=$(aws ssm send-command $PROFILE \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --parameters '{"commands":["echo Hostname: $(hostname)", "echo Kernel: $(uname -r)", "echo OS: $(grep PRETTY_NAME /etc/os-release)"]}' \
      --comment "Linux: Hostname, Kernel, OS" \
      --query "Command.CommandId" --output text 2>&1)
  fi

  echo "$cmd_id"
}

# ==============================
# Process each instance
# ==============================
while read -r instance; do
  INSTANCE_ID=$(jq -r '.[0]' <<<"$instance")
  INSTANCE_STATE=$(jq -r '.[1]' <<<"$instance")
  PLATFORM=$(jq -r '.[2]' <<<"$instance")
  INSTANCE_NAME=$(jq -r '.[3][] | select(.Key=="Name") | .Value' <<<"$instance" 2>/dev/null)
  [[ -z "$INSTANCE_NAME" ]] && INSTANCE_NAME="N/A"

  echo "================================================================================" | tee -a "$OUTPUT_FILE"
  echo "INSTANCE #$instance_number: $INSTANCE_ID ($INSTANCE_NAME)" | tee -a "$OUTPUT_FILE"

  if [[ "$INSTANCE_STATE" != "running" ]]; then
    echo -e "${YELLOW}[Instance: $INSTANCE_ID] Skipped (state: $INSTANCE_STATE)${NC}" | tee -a "$OUTPUT_FILE"
    ((fail_count++))
    ((instance_number++))
    continue
  fi

  if [[ "$PLATFORM" == *"Windows"* ]]; then
    [[ "$MODE" == "linux" ]] && { echo "Skipping Windows instance (mode: $MODE)" | tee -a "$OUTPUT_FILE"; ((instance_number++)); continue; }
    OS_TYPE="Windows"
  elif [[ "$PLATFORM" == *"Linux"* || "$PLATFORM" == *"unix"* || -z "$PLATFORM" ]]; then
    [[ "$MODE" == "windows" ]] && { echo "Skipping Linux instance (mode: $MODE)" | tee -a "$OUTPUT_FILE"; ((instance_number++)); continue; }
    OS_TYPE="Linux"
  else
    echo "Unknown platform: $PLATFORM. Skipped." | tee -a "$OUTPUT_FILE"
    ((fail_count++))
    ((instance_number++))
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}[Instance: $INSTANCE_ID] Dry-run mode: command not executed${NC}" | tee -a "$OUTPUT_FILE"
    ((success_count++))
    ((instance_number++))
    continue
  fi

  CMD_ID=$(run_ssm_command "$INSTANCE_ID" "$OS_TYPE")
  if [[ "$CMD_ID" == "None" || "$CMD_ID" == *"InvalidInstanceId"* || "$CMD_ID" == *"AccessDenied"* || "$CMD_ID" == *"UnsupportedPlatformType"* ]]; then
    echo -e "${RED}[Instance: $INSTANCE_ID] ERROR: Could not send SSM command${NC}" | tee -a "$OUTPUT_FILE"
    ((fail_count++))
    ((instance_number++))
    continue
  fi

  echo -e "${GREEN}[Instance: $INSTANCE_ID] Waiting for result...${NC}"
  for attempt in {1..10}; do
    STATUS=$(aws ssm list-command-invocations $PROFILE \
      --command-id "$CMD_ID" \
      --instance-id "$INSTANCE_ID" \
      --query "CommandInvocations[0].Status" \
      --output text 2>/dev/null)

    [[ "$STATUS" == "Success" ]] && break
    [[ "$STATUS" =~ (Failed|Cancelled|TimedOut) ]] && {
      echo -e "${RED}[Instance: $INSTANCE_ID] ERROR: $STATUS${NC}" | tee -a "$OUTPUT_FILE"
      ((fail_count++))
      ((instance_number++))
      continue 2
    }
    sleep 3
  done

  OUTPUT=$(aws ssm list-command-invocations $PROFILE \
    --command-id "$CMD_ID" \
    --details \
    --query "CommandInvocations[0].CommandPlugins[0].Output" \
    --output text 2>/dev/null)

  echo "$OUTPUT" | tee -a "$OUTPUT_FILE"
  echo >> "$OUTPUT_FILE"

  ((success_count++))
  ((instance_number++))
done < <(jq -c '.[]' <<<"$instances_json")

# ==============================
# Summary
# ==============================
end_time=$(date +%s)
elapsed=$((end_time - start_time))
success_rate=$(( (success_count * 100) / (success_count + fail_count + 1) ))

echo -e "\n================================================================================"
echo -e "Run complete. Results:"
echo -e "  ${GREEN}Successes: $success_count${NC}"
echo -e "  ${RED}Failures:  $fail_count${NC}"
echo -e "  Duration:  ${elapsed}s"
echo -e "  Success %: ${success_rate}%"
echo -e "Reports:"
echo -e "  - Raw output: $OUTPUT_FILE"
echo -e "  - Parsed CSV: $CSV_FILE"
echo -e "  - Excel file: $XLSX_FILE"

# ==============================
# Python Parser + Excel Sort
# ==============================
python3 <<EOF
import re, csv, sys, subprocess
from pathlib import Path

CSV_FILE = "$CSV_FILE"
XLSX_FILE = "$XLSX_FILE"
MD_FILE = "$OUTPUT_FILE"

try:
    import pandas as pd
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "pandas", "openpyxl"])
    import pandas as pd

with open(MD_FILE, "r", encoding="utf-8") as f:
    data = f.read()

# Strip ANSI colors
data = re.sub(r'\x1B\[[0-?]*[ -/]*[@-~]', '', data)
sections = re.split(r'=+', data)
rows = []

for section in sections:
    m = re.search(r'INSTANCE\s+#(\d+):\s+(i-[\w\d]+) \((.*?)\)', section)
    if not m: 
        continue
    num, iid, name = m.groups()
    os_type = "Windows" if "Uptime:" in section else ("Linux" if "Hostname:" in section else "Unknown")
    uptime = falcon = updates = hostname = kernel = os_name = status = "N/A"

    if "Dry-run" in section:
        status = "Dry-Run"
    elif "Skipped" in section:
        status = "Skipped"
    elif "ERROR" in section:
        status = "Error"
    else:
        status = "OK"
        if os_type == "Windows":
            uptime = re.search(r'Uptime:\s+(.*)', section)
            uptime = uptime.group(1).strip() if uptime else "N/A"
            falcon = re.search(r'Falcon Service:\s+(.*)', section)
            falcon = falcon.group(1).strip() if falcon else "N/A"
            updates_list = re.findall(r'- (.+)', section)
            updates = ", ".join([u.strip() for u in updates_list if u != "None"]) or "None"
        elif os_type == "Linux":
            hostname = re.search(r'Hostname:\s+(.*)', section)
            hostname = hostname.group(1).strip() if hostname else "N/A"
            kernel = re.search(r'Kernel:\s+(.*)', section)
            kernel = kernel.group(1).strip() if kernel else "N/A"
            os_match = re.search(r'OS:\s+PRETTY_NAME="(.*)"', section)
            os_name = os_match.group(1).strip() if os_match else "N/A"

    rows.append([num, iid, name, os_type, uptime, falcon, updates, hostname, kernel, os_name, status])

headers = ["#", "Instance ID", "Instance Name", "OS Type", "Uptime", "Falcon Service", "Pending Updates", "Hostname", "Kernel", "OS", "Status"]

df = pd.DataFrame(rows, columns=headers)
df.sort_values(by=["Status", "Instance ID"], inplace=True)  # Sorted Excel
df.to_csv(CSV_FILE, index=False)
df.to_excel(XLSX_FILE, sheet_name="Report", index=False)

from openpyxl import load_workbook
from openpyxl.worksheet.table import Table, TableStyleInfo

wb = load_workbook(XLSX_FILE)
ws = wb["Report"]
table_range = f"A1:{chr(65+len(headers)-1)}{len(df)+1}"
table = Table(displayName="EC2Report", ref=table_range)
style = TableStyleInfo(name="TableStyleMedium9", showRowStripes=True, showColumnStripes=False)
table.tableStyleInfo = style
ws.add_table(table)

# Auto-fit column widths
for col in ws.columns:
    max_len = max(len(str(cell.value)) for cell in col if cell.value)
    ws.column_dimensions[col[0].column_letter].width = max_len + 2

wb.save(XLSX_FILE)
print(f"CSV saved as: {CSV_FILE}")
print(f"Excel saved as: {XLSX_FILE}")
EOF
