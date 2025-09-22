#!/bin/bash

echo "=== EC2 Instance Creator (Linux & Windows with SSM) ==="

# Function to prompt input with defaults
prompt_input() {
    local PROMPT=$1
    local DEFAULT=$2
    read -p "$PROMPT [$DEFAULT]: " VAR
    echo ${VAR:-$DEFAULT}
}

# Function to get default AMI based on OS choice
get_default_ami() {
    local REGION=$1
    local OS=$2

    case $OS in
        Windows*)
            aws ec2 describe-images \
                --owners amazon \
                --filters "Name=name,Values=Windows_Server-2022-English-Full-Base*" "Name=state,Values=available" \
                --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
                --region $REGION \
                --output text
            ;;
        Ubuntu*)
            aws ec2 describe-images \
                --owners 099720109477 \
                --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
                --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
                --region $REGION \
                --output text
            ;;
        AmazonLinux*)
            aws ec2 describe-images \
                --owners amazon \
                --filters "Name=name,Values=amzn2-ami-hvm-2.*-x86_64-gp2" "Name=state,Values=available" \
                --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
                --region $REGION \
                --output text
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to get default key pair (or create one)
get_default_keypair() {
    local REGION=$1
    local OS=$2
    local DEFAULT_KEY="Linux"

    if [[ "$OS" =~ Windows ]]; then
        DEFAULT_KEY="Windows"
    fi

    if aws ec2 describe-key-pairs --key-names "$DEFAULT_KEY" --region $REGION &>/dev/null; then
        echo "$DEFAULT_KEY"
    else
        echo "Creating default key pair '$DEFAULT_KEY'..."
        aws ec2 create-key-pair --key-name "$DEFAULT_KEY" --query 'KeyMaterial' --output text --region $REGION > "${DEFAULT_KEY}.pem"
        chmod 400 "${DEFAULT_KEY}.pem"
        echo "$DEFAULT_KEY"
    fi
}

# Function to get default security group
get_default_sg() {
    local REGION=$1
    aws ec2 describe-security-groups --filters Name=group-name,Values=default --query "SecurityGroups[0].GroupId" --output text --region $REGION
}

# --- User Inputs ---
INSTANCE_NAME=$(prompt_input "Enter instance name" "MyEC2Instance")
REGION=$(prompt_input "Enter AWS region" "us-east-1")
OS_CHOICE=$(prompt_input "Enter OS (Windows/Ubuntu/AmazonLinux)" "AmazonLinux")
AMI_ID=$(prompt_input "Enter AMI ID (leave blank for default)" "")
INSTANCE_TYPE=$(prompt_input "Enter instance type" "t2.micro")
KEY_NAME=$(prompt_input "Enter key pair name (leave blank for default)" "")
SG_ID=$(prompt_input "Enter security group ID (leave blank for default)" "")
SUBNET_ID=$(prompt_input "Enter subnet ID (optional)" "")
INSTANCE_COUNT=$(prompt_input "Enter number of instances to create" "1")

# --- Defaults if missing ---
if [[ -z "$AMI_ID" ]]; then
    echo "Fetching default AMI for $OS_CHOICE in $REGION..."
    AMI_ID=$(get_default_ami "$REGION" "$OS_CHOICE")
    if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
        echo "❌ Could not fetch a default AMI for $OS_CHOICE in $REGION."
        exit 1
    fi
    echo "Using AMI: $AMI_ID"
fi

if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME=$(get_default_keypair "$REGION" "$OS_CHOICE")
    echo "Using key pair: $KEY_NAME"
fi

if [[ -z "$SG_ID" ]]; then
    SG_ID=$(get_default_sg "$REGION")
    echo "Using default security group: $SG_ID"
fi

# --- Build user-data script ---
USER_DATA=""

if [[ "$OS_CHOICE" =~ Windows ]]; then
    echo "Configuring Windows user-data for SSM..."
    USER_DATA="<powershell>
# Install SSM Agent if not installed
\$ssmPath = 'C:\\Program Files\\Amazon\\SSM\\amazon-ssm-agent.exe'
if (-Not (Test-Path \$ssmPath)) {
    \$url = 'https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/windows_amd64/AmazonSSMAgentSetup.exe'
    Invoke-WebRequest -Uri \$url -OutFile 'C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe'
    Start-Process 'C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe' -ArgumentList '/quiet' -Wait
}
Start-Service AmazonSSMAgent
Set-Service AmazonSSMAgent -StartupType Automatic
</powershell>"
else
    USER_DATA="#!/bin/bash
# Update system packages and install SSM agent
if command -v yum &>/dev/null; then
    yum update -y
    yum install -y amazon-ssm-agent
elif command -v apt-get &>/dev/null; then
    apt-get update -y
    apt-get install -y amazon-ssm-agent
fi

# Enable and start SSM agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
"
fi

# --- Confirm inputs ---
echo ""
echo "Launching $INSTANCE_COUNT EC2 instance(s) with the following configuration:"
echo "Name: $INSTANCE_NAME"
echo "Region: $REGION"
echo "AMI ID: $AMI_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Key Pair: $KEY_NAME"
echo "Security Group ID: $SG_ID"
echo "Subnet ID: ${SUBNET_ID:-default}"
echo ""

read -p "Proceed? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

# --- Launch instances ---
RUN_CMD=(aws ec2 run-instances --image-id "$AMI_ID" --count "$INSTANCE_COUNT" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --region "$REGION" --query "Instances[*].InstanceId" --output text)
if [[ -n "$SUBNET_ID" ]]; then
    RUN_CMD+=(--subnet-id "$SUBNET_ID")
fi
RUN_CMD+=(--user-data "$USER_DATA")

INSTANCE_IDS=$("${RUN_CMD[@]}")

if [[ -z "$INSTANCE_IDS" ]]; then
    echo "❌ Failed to launch EC2 instance(s)."
    exit 1
fi

# Tag instances
for ID in $INSTANCE_IDS; do
    aws ec2 create-tags --resources $ID --tags Key=Name,Value=$INSTANCE_NAME --region $REGION
done

# Wait for running
echo "Waiting for instance(s) to reach 'running' state..."
aws ec2 wait instance-running --instance-ids $INSTANCE_IDS --region $REGION

# Retrieve public IPs
PUBLIC_IPS=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --region $REGION --query "Reservations[*].Instances[*].PublicIpAddress" --output text)

echo "✅ EC2 instance(s) created successfully!"
echo "Instance ID(s): $INSTANCE_IDS"
echo "Public IP(s): $PUBLIC_IPS"
echo "Name: $INSTANCE_NAME"
echo "Region: $REGION"