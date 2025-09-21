#!/bin/bash
#
# This script checks for and offers to install all dependencies required by the
# SSM EC2 reporting tool. It is designed for Debian-based systems like Ubuntu (common in WSL).

set -e

# ==============================
# Colors for terminal output
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}--- SSM EC2 Report Script Prerequisite Checker ---${NC}"

# ==============================
# Define Dependencies
# ==============================
# Map required commands to the APT package that provides them
declare -A REQUIRED_COMMANDS
REQUIRED_COMMANDS=(
    ["aws"]="awscli"
    ["jq"]="jq"
    ["python3"]="python3"
    ["pip3"]="python3-pip"
    ["dos2unix"]="dos2unix"
)

# List of required Python packages
PIP_PACKAGES=("pandas" "openpyxl")

# Arrays to hold the names of missing packages
missing_apt_packages=()
missing_pip_packages=()

# ==============================
# Check System Packages
# ==============================
echo -e "\n${BLUE}1. Checking for required system commands...${NC}"
for cmd in "${!REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        pkg=${REQUIRED_COMMANDS[$cmd]}
        echo -e "${YELLOW}  -> MISSING command: '$cmd' (from package '$pkg')${NC}"
        missing_apt_packages+=("$pkg")
    else
        echo -e "${GREEN}  -> Found: '$cmd'${NC}"
    fi
done

# ==============================
# Check Python Packages
# ==============================
if command -v "pip3" &> /dev/null; then
    echo -e "\n${BLUE}2. Checking for required Python libraries...${NC}"
    for pkg in "${PIP_PACKAGES[@]}"; do
        if ! python3 -c "import $pkg" &> /dev/null; then
            echo -e "${YELLOW}  -> MISSING Python library: '$pkg'${NC}"
            missing_pip_packages+=("$pkg")
        else
            echo -e "${GREEN}  -> Found: '$pkg'${NC}"
        fi
    done
else
    echo -e "\n${YELLOW}Skipping Python library check because 'pip3' is not installed.${NC}"
fi

# ==============================
# Report and Install
# ==============================
if [ ${#missing_apt_packages[@]} -eq 0 ] && [ ${#missing_pip_packages[@]} -eq 0 ]; then
    echo -e "\n${GREEN}✅ All prerequisites are met! You are ready to run the script.${NC}"
    exit 0
fi

echo -e "\n${RED}❗️ Some prerequisites are missing.${NC}"
echo "The script needs to install the following packages:"
if [ ${#missing_apt_packages[@]} -gt 0 ]; then
    echo "  - System packages: ${missing_apt_packages[*]}"
fi
if [ ${#missing_pip_packages[@]} -gt 0 ]; then
    echo "  - Python libraries: ${missing_pip_packages[*]}"
fi

echo ""
read -p "Do you want to attempt installation now? (y/n) " -n 1 -r
echo # Move to a new line

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled. Please install the missing packages manually."
    exit 1
fi

# --- Proceed with installation ---
if [ ${#missing_apt_packages[@]} -gt 0 ]; then
    echo -e "\n${BLUE}Installing system packages... (This may require your password for 'sudo')${NC}"
    sudo apt-get update
    sudo apt-get install -y "${missing_apt_packages[@]}"
fi

if [ ${#missing_pip_packages[@]} -gt 0 ]; then
    echo -e "\n${BLUE}Installing Python libraries...${NC}"
    pip3 install "${missing_pip_packages[@]}"
fi

echo -e "\n${GREEN}✅ Installation complete! All prerequisites should now be met.${NC}"
echo "You can now run the main script."