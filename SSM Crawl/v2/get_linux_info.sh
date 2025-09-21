#!/bin/bash
# This script gathers basic Linux info and outputs it as a JSON object.

# Safely get OS pretty name from /etc/os-release
os_name="N/A"
if [ -f /etc/os-release ]; then
    os_name=$(. /etc/os-release && echo "$PRETTY_NAME")
fi

# Gather other details
hostname=$(hostname -f 2>/dev/null || hostname)
kernel=$(uname -r)

# Use jq to safely create a JSON object
# -n: read no input | --arg: sets a named string variable
jq -n \
  --arg h "$hostname" \
  --arg k "$kernel" \
  --arg o "$os_name" \
  '{hostname: $h, kernel: $k, os: $o}'