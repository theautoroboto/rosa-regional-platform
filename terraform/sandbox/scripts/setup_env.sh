#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting environment setup...${NC}"

# Determine script directory for relative paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Create a temporary directory for downloads
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary directory..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 1. Install/Verify Terraform
echo -e "${YELLOW}Checking Terraform...${NC}"
REQUIRED_TF_VERSION="1.5.7"

if ! command -v terraform &> /dev/null; then
    echo "Terraform not found. Attempting to install version ${REQUIRED_TF_VERSION}..."
    # Detect OS/Arch (simplified for Linux amd64 as per typical CI environments)
    OS="linux"
    ARCH="amd64"

    wget -P "$TEMP_DIR" "https://releases.hashicorp.com/terraform/${REQUIRED_TF_VERSION}/terraform_${REQUIRED_TF_VERSION}_${OS}_${ARCH}.zip"
    unzip "$TEMP_DIR/terraform_${REQUIRED_TF_VERSION}_${OS}_${ARCH}.zip" -d "$TEMP_DIR"
    sudo mv "$TEMP_DIR/terraform" /usr/local/bin/
    echo -e "${GREEN}Terraform installed successfully.${NC}"
else
    CURRENT_TF_VERSION=$(terraform version | head -n1 | cut -d 'v' -f 2)
    echo "Terraform is already installed (Version: ${CURRENT_TF_VERSION})."
fi

# 2. Install/Verify AWS CLI
echo -e "${YELLOW}Checking AWS CLI...${NC}"
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Installing..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TEMP_DIR/awscliv2.zip"
    unzip -q "$TEMP_DIR/awscliv2.zip" -d "$TEMP_DIR"
    sudo "$TEMP_DIR/aws/install"
    echo -e "${GREEN}AWS CLI installed successfully.${NC}"
else
    echo "AWS CLI is already installed."
fi

# 3. Install Python Dependencies
echo -e "${YELLOW}Installing Python dependencies...${NC}"
REQUIREMENTS_PATH="$SCRIPT_DIR/requirements.txt"
if [ -f "$REQUIREMENTS_PATH" ]; then
    pip install -r "$REQUIREMENTS_PATH"
else
    echo "requirements.txt not found at $REQUIREMENTS_PATH. Skipping pip install."
fi

# 4. Install/Verify cloud-nuke
echo -e "${YELLOW}Checking cloud-nuke...${NC}"
if ! command -v cloud-nuke &> /dev/null; then
    echo "cloud-nuke not found. Installing..."
    CLOUD_NUKE_VERSION="v0.37.1"
    wget -P "$TEMP_DIR" "https://github.com/gruntwork-io/cloud-nuke/releases/download/${CLOUD_NUKE_VERSION}/cloud-nuke_linux_amd64"
    mv "$TEMP_DIR/cloud-nuke_linux_amd64" "$TEMP_DIR/cloud-nuke"
    chmod +x "$TEMP_DIR/cloud-nuke"
    sudo mv "$TEMP_DIR/cloud-nuke" /usr/local/bin/
    echo -e "${GREEN}cloud-nuke installed successfully.${NC}"
else
    echo "cloud-nuke is already installed."
fi

echo -e "${GREEN}Setup complete!${NC}"
