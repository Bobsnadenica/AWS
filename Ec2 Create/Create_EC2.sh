#!/bin/bash

# Interactive EC2 creation script using AWS CLI

echo "=== EC2 Instance Creator ==="

# Prompt user for inputs
read -p "Enter instance name: " INSTANCE_NAME
read -p "Enter AWS region (e.g. us-east-1): " REGION
read -p "Enter AMI ID (e.g. ami-1234567890abcdef0): " AMI_ID
read -p "Enter instance type (e.g. t2.micro): " INSTANCE_TYPE
read -p "Enter key pair name: " KEY_NAME
read -p "Enter security group ID: " SG_ID
read -p "Enter subnet ID: " SUBNET_ID

# Create instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --count 1 \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --region $REGION \
  --query "Instances[0].InstanceId" \
  --output text)

# Tag instance with name
aws ec2 create-tags \
  --resources $INSTANCE_ID \
  --tags Key=Name,Value=$INSTANCE_NAME \
  --region $REGION

echo "✅ EC2 instance created!"
echo "Instance ID: $INSTANCE_ID"
echo "Name: $INSTANCE_NAME"
echo "Region: $REGION"