#!/bin/bash

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arrays to track installation status
declare -A INSTALLED_PACKAGES=()
declare -A SKIPPED_PACKAGES=()
declare -A FAILED_PACKAGES=()
declare -A SYSTEM_CHANGES=()

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

# Function to check command status and track results
check_status() {
    local command_name=$1
    local status=$2
    if [ $status -eq 0 ]; then
        INSTALLED_PACKAGES[$command_name]="Installed successfully"
        print_success "$command_name completed successfully"
        return 0
    else
        FAILED_PACKAGES[$command_name]="Installation failed"
        print_error "$command_name failed"
        return 1
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a file contains a specific line
file_contains() {
    grep -Fxq "$1" "$2" 2>/dev/null
}

# Function to add a system change to tracking
track_change() {
    SYSTEM_CHANGES[$1]="$2"
}

# Function to check system requirements
check_system_requirements() {
    print_section "Checking System Requirements"
    
    local required_space=5120  # 5GB in MB
    local available_space=$(df -m / | awk 'NR==2 {print $4}')
    
    if [ $available_space -lt $required_space ]; then
        print_error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        exit 1
    fi
    print_success "Disk space check passed"
    
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        print_error "Script requires sudo privileges"
        exit 1
    fi
    print_success "Privilege check passed"
}

# Function to print installation summary
print_summary() {
    print_section "Installation Summary"
    
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${GREEN}Successfully Installed:${NC}"
        for pkg in "${!INSTALLED_PACKAGES[@]}"; do
            echo "  ✔ $pkg: ${INSTALLED_PACKAGES[$pkg]}"
        done
    fi
    
    if [ ${#SKIPPED_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped (Already Installed):${NC}"
        for pkg in "${!SKIPPED_PACKAGES[@]}"; do
            echo "  ↷ $pkg: ${SKIPPED_PACKAGES[$pkg]}"
        done
    fi
    
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n${RED}Failed Installations:${NC}"
        for pkg in "${!FAILED_PACKAGES[@]}"; do
            echo "  ✖ $pkg: ${FAILED_PACKAGES[$pkg]}"
        done
    fi
    
    if [ ${#SYSTEM_CHANGES[@]} -gt 0 ]; then
        echo -e "\n${BLUE}System Changes:${NC}"
        for change in "${!SYSTEM_CHANGES[@]}"; do
            echo "  • $change: ${SYSTEM_CHANGES[$change]}"
        done
    fi
}

# Function to verify and load environment
verify_and_load_environment() {
    print_section "Verifying and Loading Environment"
    
    # Verify PATH includes necessary directories
    local dirs_to_check=("/usr/local/bin" "/usr/bin" "/usr/local/sbin")
    for dir in "${dirs_to_check[@]}"; do
        if [[ ":$PATH:" != *":$dir:"* ]]; then
            export PATH="$PATH:$dir"
            print_info "Added $dir to PATH"
        fi
    done
    
    # Load kubectl completion if available
    if command_exists kubectl; then
        source <(kubectl completion bash)
        print_success "Loaded kubectl completion"
    fi
    
    # Load Azure CLI completion if available
    if command_exists az; then
        source <(az completion bash)
        print_success "Loaded Azure CLI completion"
    fi
    
    # Verify KUBECONFIG
    if [ -f ~/.kube/config ]; then
        export KUBECONFIG=~/.kube/config
        print_success "KUBECONFIG set to ~/.kube/config"
    fi
}

# Main script starts here
print_section "Starting Non-Interactive Environment Setup"
print_info "Running in non-interactive mode with automatic yes to prompts"

# Set non-interactive frontend for apt
export DEBIAN_FRONTEND=noninteractive

# Check system requirements
check_system_requirements

# System update
print_section "Updating System Packages"
if sudo apt-get update && sudo apt-get dist-upgrade -y; then
    track_change "System Update" "Completed successfully"
else
    print_error "System update failed"
    exit 1
fi

# Install basic dependencies
print_section "Installing Basic Dependencies"
DEPS="wget gpg apt-transport-https ca-certificates curl gnupg lsb-release"
for dep in $DEPS; do
    if ! command_exists $dep; then
        sudo apt-get install -y $dep
        check_status $dep $?
    else
        SKIPPED_PACKAGES[$dep]="Already installed"
        print_info "$dep already installed"
    fi
done

# VS Code setup
print_section "Setting up VS Code Repository"
if ! command_exists code; then
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
        sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
    rm -f packages.microsoft.gpg
    track_change "VS Code Repository" "Added"
else
    SKIPPED_PACKAGES["VS Code"]="Already installed"
    print_info "VS Code repository already configured"
fi

# Azure CLI setup
print_section "Setting up Azure CLI Repository"
if ! command_exists az; then
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
    track_change "Azure CLI Repository" "Added"
else
    SKIPPED_PACKAGES["Azure CLI"]="Already installed"
    print_info "Azure CLI repository already configured"
fi

# K3s setup
print_section "Installing K3s"
if ! command_exists k3s; then
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    check_status "K3s" $?
    track_change "K3s Installation" "Completed"
else
    SKIPPED_PACKAGES["K3s"]="Already installed"
    print_info "K3s already installed"
fi

# Kubernetes tools setup
print_section "Setting up Kubernetes Tools"
if ! command_exists kubectl; then
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
    track_change "Kubernetes Repository" "Added"
else
    SKIPPED_PACKAGES["kubectl"]="Already installed"
    print_info "Kubernetes tools already configured"
fi

# Helm setup
print_section "Setting up Helm Repository"
if ! command_exists helm; then
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
        sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    track_change "Helm Repository" "Added"
else
    SKIPPED_PACKAGES["Helm"]="Already installed"
    print_info "Helm repository already configured"
fi

# Install all tools
print_section "Installing Tools"
sudo apt-get update
TOOLS="code azure-cli git kubectl helm"
for tool in $TOOLS; do
    if ! command_exists $tool; then
        sudo apt-get install -y $tool
        check_status $tool $?
    else
        SKIPPED_PACKAGES[$tool]="Already installed"
        print_info "$tool already installed"
    fi
done

# Configure K3s
print_section "Configuring K3s"
if [ ! -f ~/.kube/config ]; then
    mkdir -p ~/.kube
    sudo KUBECONFIG=~/.kube/config:/etc/rancher/k3s/k3s.yaml kubectl config view --flatten > ~/.kube/merged
    mv ~/.kube/merged ~/.kube/config
    chmod 0600 ~/.kube/config
    export KUBECONFIG=~/.kube/config
    kubectl config use-context default
    track_change "K3s Configuration" "Created new config"
else
    print_info "K3s configuration already exists"
    SKIPPED_PACKAGES["K3s config"]="Already configured"
fi

# Configure system settings
print_section "Configuring System Settings"
SYSCTL_SETTINGS=(
    "fs.inotify.max_user_instances=8192"
    "fs.inotify.max_user_watches=524288"
    "fs.file-max=100000"
)

for setting in "${SYSCTL_SETTINGS[@]}"; do
    if ! file_contains "$setting" /etc/sysctl.conf; then
        echo "$setting" | sudo tee -a /etc/sysctl.conf
        track_change "System Setting" "Added $setting"
    else
        print_info "System setting $setting already configured"
    fi
done
sudo sysctl -p

# Verify and load environment
verify_and_load_environment

# Print installation summary
print_summary

print_section "Final Steps"
print_info "To complete the setup, please run:"
echo "source ~/.bashrc"
print_success "Environment setup completed successfully"