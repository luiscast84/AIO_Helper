#!/bin/bash

# Color codes for pretty output - makes the script output more readable
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arrays to track installation status throughout the script execution
declare -A INSTALLED_PACKAGES=()     # Tracks newly installed packages
declare -A SKIPPED_PACKAGES=()       # Tracks already installed packages
declare -A FAILED_PACKAGES=()        # Tracks failed installations
declare -A SYSTEM_CHANGES=()         # Tracks system configuration changes

# Function to print section headers with consistent formatting
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Function to print success messages with green checkmark
print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

# Function to print error messages with red X
print_error() {
    echo -e "${RED}✖ $1${NC}"
}

# Function to print information messages with yellow info symbol
print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to check command status and track results
# Parameters:
#   $1: command name
#   $2: exit status of the command
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

# Function to check if a command exists in the system PATH
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a file contains a specific line
# Parameters:
#   $1: line to search for
#   $2: file to search in
file_contains() {
    grep -Fxq "$1" "$2" 2>/dev/null
}

# Function to add a system change to tracking
# Parameters:
#   $1: change description
#   $2: change details
track_change() {
    SYSTEM_CHANGES[$1]="$2"
}

# Function to check system requirements before installation
check_system_requirements() {
    print_section "Checking System Requirements"
    
    # Check for minimum required disk space (5GB)
    local required_space=5120  # 5GB in MB
    local available_space=$(df -m / | awk 'NR==2 {print $4}')
    
    if [ $available_space -lt $required_space ]; then
        print_error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        exit 1
    fi
    print_success "Disk space check passed"
    
    # Check for sudo privileges
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        print_error "Script requires sudo privileges"
        exit 1
    fi
    print_success "Privilege check passed"
}

# Function to print installation summary at the end of script execution
print_summary() {
    print_section "Installation Summary"
    
    # Print successfully installed packages
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${GREEN}Successfully Installed:${NC}"
        for pkg in "${!INSTALLED_PACKAGES[@]}"; do
            echo "  ✔ $pkg: ${INSTALLED_PACKAGES[$pkg]}"
        done
    fi
    
    # Print skipped packages (already installed)
    if [ ${#SKIPPED_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped (Already Installed):${NC}"
        for pkg in "${!SKIPPED_PACKAGES[@]}"; do
            echo "  ↷ $pkg: ${SKIPPED_PACKAGES[$pkg]}"
        done
    fi
    
    # Print failed installations
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n${RED}Failed Installations:${NC}"
        for pkg in "${!FAILED_PACKAGES[@]}"; do
            echo "  ✖ $pkg: ${FAILED_PACKAGES[$pkg]}"
        done
    fi
    
    # Print system changes made
    if [ ${#SYSTEM_CHANGES[@]} -gt 0 ]; then
        echo -e "\n${BLUE}System Changes:${NC}"
        for change in "${!SYSTEM_CHANGES[@]}"; do
            echo "  • $change: ${SYSTEM_CHANGES[$change]}"
        done
    fi
}

# Function to verify and load environment configurations
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
    
    # Configure kubectl bash completion if kubectl is available
    if command_exists kubectl; then
        # Ensure bash-completion is installed
        if ! dpkg -l | grep -q bash-completion; then
            sudo apt-get install -y bash-completion
        fi
        
        # Add kubectl completion to bashrc if not already present
        if ! grep -q "kubectl completion bash" ~/.bashrc; then
            kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
            echo 'source <(kubectl completion bash)' >>~/.bashrc
            print_success "Added kubectl completion to ~/.bashrc"
        else
            print_info "kubectl completion already configured"
        fi
    fi
    
    # Configure Azure CLI completion if available
    if command_exists az; then
        if ! grep -q "az completion bash" ~/.bashrc; then
            az completion bash | sudo tee /etc/bash_completion.d/azure-cli > /dev/null
            echo 'source <(az completion bash)' >>~/.bashrc
            print_success "Added Azure CLI completion to ~/.bashrc"
        else
            print_info "Azure CLI completion already configured"
        fi
    fi
    
    # Verify KUBECONFIG environment variable
    if [ -f ~/.kube/config ]; then
        export KUBECONFIG=~/.kube/config
        print_success "KUBECONFIG set to ~/.kube/config"
    fi
}

# Main script execution starts here
print_section "Starting Non-Interactive Environment Setup"
print_info "Running in non-interactive mode with automatic yes to prompts"

# Set non-interactive frontend for apt to prevent prompts
export DEBIAN_FRONTEND=noninteractive

# Perform system requirement checks
check_system_requirements

# Update system packages
print_section "Updating System Packages"
if sudo apt-get update; then
    track_change "APT Update" "Completed successfully"
else
    print_error "APT update failed"
    exit 1
fi

# Install basic system dependencies
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

# Configure VS Code repository
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

# Configure Azure CLI repository and install Azure CLI with Arc extension
print_section "Setting up Azure CLI Repository"
if ! command_exists az; then
    # Add Azure CLI repository
    sudo mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
    sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
    AZ_DIST=$(lsb_release -cs)
    echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources
    track_change "Azure CLI Repository" "Added"
    
    # Install Azure CLI
    sudo apt-get update
    sudo apt-get install -y azure-cli
    check_status "Azure CLI" $?
    
    # Install Azure Arc extension
    az extension add --name connectedk8s --version 1.9.3
    check_status "Azure Arc Extension" $?
    track_change "Azure Arc Extension" "Installed version 1.9.3"
else
    SKIPPED_PACKAGES["Azure CLI"]="Already installed"
    print_info "Azure CLI repository already configured"
    
    # Check and install Arc extension even if Azure CLI exists
    if ! az extension show --name connectedk8s &>/dev/null; then
        az extension add --name connectedk8s --version 1.9.3
        check_status "Azure Arc Extension" $?
        track_change "Azure Arc Extension" "Installed version 1.9.3"
    else
        SKIPPED_PACKAGES["Azure Arc Extension"]="Already installed"
        print_info "Azure Arc extension already installed"
    fi
fi

# Install and configure K3s
print_section "Installing K3s"
if ! command_exists k3s; then
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    check_status "K3s" $?
    track_change "K3s Installation" "Completed"
    
    # Configure kubectl access
    mkdir -p $HOME/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    chmod 600 $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    
    # Verify kubectl access
    if kubectl get nodes &>/dev/null; then
        print_success "kubectl configured successfully"
        track_change "kubectl Configuration" "Completed"
    else
        print_error "kubectl configuration failed"
        FAILED_PACKAGES["kubectl configuration"]="Failed to configure access"
    fi
else
    SKIPPED_PACKAGES["K3s"]="Already installed"
    print_info "K3s already installed"
    
    # Ensure kubectl is properly configured even if K3s exists
    if [ ! -f $HOME/.kube/config ]; then
        mkdir -p $HOME/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
        chmod 600 $HOME/.kube/config
        export KUBECONFIG=$HOME/.kube/config
        track_change "kubectl Configuration" "Updated"
    fi
fi

# Configure Kubernetes tools repository
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

# Configure Helm repository
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

# Install K9s
print_section "Installing K9s"
if ! command_exists k9s; then
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    print_info "Installing K9s version ${K9S_VERSION}"
    curl -sL https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz | sudo tar xz -C /usr/local/bin k9s
    sudo chmod +x /usr/local/bin/k9s
    check_status "K9s" $?
    track_change "K9s Installation" "Version ${K9S_VERSION}"
else
    SKIPPED_PACKAGES["K9s"]="Already installed"
    print_info "K9s already installed"
fi

# Install MQTT Explorer
    print_section "Installing MQTT Explorer"
    if ! dpkg -l | grep -q mqtt-explorer; then
        print_info "Installing MQTT Explorer dependencies"
        sudo apt-get install -y libgconf-2-4 libatk1.0-0 libatk-bridge2.0-0 libgdk-pixbuf2.0-0 libgtk-3-0 libgbm1 libnss3 libxss1
        
        # Download and install the latest .deb package
        MQTT_EXPLORER_VERSION="0.4.0-beta1"
        MQTT_DEB="mqtt-explorer_${MQTT_EXPLORER_VERSION}_amd64.deb"
        print_info "Downloading MQTT Explorer ${MQTT_EXPLORER_VERSION}"
        wget -q "https://github.com/thomasnordquist/MQTT-Explorer/releases/download/v${MQTT_EXPLORER_VERSION}/${MQTT_DEB}"
        
        if [ -f "${MQTT_DEB}" ]; then
            sudo dpkg -i "${MQTT_DEB}"
            sudo apt-get install -f -y  # Install any missing dependencies
            rm "${MQTT_DEB}"
            check_status "MQTT Explorer" $?
            track_change "MQTT Explorer Installation" "Version ${MQTT_EXPLORER_VERSION}"
        else
            print_error "Failed to download MQTT Explorer"
            FAILED_PACKAGES["MQTT Explorer"]="Download failed"
        fi
    else
        SKIPPED_PACKAGES["MQTT Explorer"]="Already installed"
        print_info "MQTT Explorer already installed"
    fi
fi

# Install all required tools
print_section "Installing Tools"
sudo apt-get update
TOOLS="code azure-cli git kubectl helm jq"
for tool in $TOOLS; do
    if ! command_exists $tool; then
        sudo apt-get install -y $tool
        check_status $tool $?
    else
        SKIPPED_PACKAGES[$tool]="Already installed"
        print_info "$tool already installed"
    fi
done

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

# Verify and load environment configurations
verify_and_load_environment

# Print installation summary
print_summary

# Print final instructions
print_section "Final Steps"
print_info "To complete the setup, please run:"
echo "source ~/.bashrc"

# Print additional usage information
print_section "Additional Tools Information"
echo -e "${YELLOW}New tools installed:${NC}"
echo -e "1. K9s - Kubernetes CLI To Manage Your Clusters In Style"
echo "   - Launch with: k9s"
echo "   - Exit with: Ctrl+C or :quit"
echo
echo -e "2. MQTT Explorer - MQTT Client for debugging and exploring MQTT instances"
echo "   - Launch from applications menu or run: mqtt-explorer"
echo "   - Default port for MQTT connections: 1883"

print_success "Environment setup completed successfully"