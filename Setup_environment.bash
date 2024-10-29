#!/bin/bash

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

# Function to print error messages
print_error() {
    echo -e "${RED}✖ $1${NC}"
}

# Function to print info messages
print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to check command status and exit if failed
check_status() {
    if [ $? -eq 0 ]; then
        print_success "$1 completed successfully"
    else
        print_error "$1 failed"
        exit 1
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Main script starts here
print_section "Starting Environment Setup"
print_info "This script will set up your development environment with VS Code, Kubernetes (k3s), and Azure CLI"

# System update
print_section "Updating System Packages"
sudo apt-get update && sudo apt-get dist-upgrade --assume-yes
check_status "System update"

# Install basic dependencies
print_section "Installing Basic Dependencies"
print_info "Installing: wget, gpg, apt-transport-https, ca-certificates, curl, gnupg, lsb-release"
sudo apt-get install -y wget gpg apt-transport-https ca-certificates curl gnupg lsb-release
check_status "Dependencies installation"

# VS Code setup
print_section "Setting up VS Code Repository"
if ! command_exists code; then
    print_info "Adding Microsoft VS Code repository"
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
        sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
    rm -f packages.microsoft.gpg
    check_status "VS Code repository setup"
else
    print_info "VS Code is already installed"
fi

# Azure CLI setup
print_section "Setting up Azure CLI Repository"
if ! command_exists az; then
    print_info "Adding Microsoft Azure CLI repository"
    sudo mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
    sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
    AZ_DIST=$(lsb_release -cs)
    echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources
    check_status "Azure CLI repository setup"
else
    print_info "Azure CLI is already installed"
fi

# K3s setup
print_section "Installing K3s"
if ! command_exists k3s; then
    print_info "Installing K3s"
    curl -sfL https://get.k3s.io | sh -
    check_status "K3s installation"
else
    print_info "K3s is already installed"
fi

# Kubernetes tools setup
print_section "Setting up Kubernetes Tools"
print_info "Adding Kubernetes repository"
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
check_status "Kubernetes repository setup"

# Helm setup
print_section "Setting up Helm Repository"
print_info "Adding Helm repository"
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
    sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
check_status "Helm repository setup"

# Install all tools
print_section "Installing Tools"
print_info "Updating package lists"
sudo apt-get update
print_info "Installing VS Code, Azure CLI, Git, kubectl, and Helm"
sudo apt-get install -y code azure-cli git kubectl helm
check_status "Tools installation"

# Configure K3s
print_section "Configuring K3s"
print_info "Setting up Kubernetes configuration"
mkdir -p ~/.kube
sudo KUBECONFIG=~/.kube/config:/etc/rancher/k3s/k3s.yaml kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config
chmod 0600 ~/.kube/config
export KUBECONFIG=~/.kube/config
kubectl config use-context default
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
check_status "K3s configuration"

# Configure system settings
print_section "Configuring System Settings"
print_info "Setting up inotify limits"
echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
echo fs.file-max = 100000 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
check_status "System settings configuration"

print_section "Installation Complete"
print_success "Environment setup completed successfully"
print_info "You may need to restart your terminal for all changes to take effect"

# Final verification
print_section "Verifying Installations"
for cmd in code az kubectl helm k3s; do
    if command_exists $cmd; then
        print_success "$cmd is installed"
    else
        print_error "$cmd installation could not be verified"
    fi
done