#!/bin/bash
#########################################################################
# Script: Complete Environment Setup for Ubuntu 22.04 LTS
# Description: Automated setup script for:
#   - Kubernetes tools (K3s, kubectl, Helm, K9s)
#   - Azure CLI and Arc extensions
#   - Development tools (VS Code, Git)
#   - Package managers (Snapd, Homebrew)
#   - Monitoring tools (MQTT Explorer, Mosquitto)
#   - Shell tools (PowerShell)
# Version: 3.1
# Last Updated: 2024-11-05
#########################################################################

# Color codes for pretty output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Arrays to track installation status and dependencies
declare -A INSTALLED_PACKAGES=()     # Tracks newly installed packages
declare -A SKIPPED_PACKAGES=()       # Tracks already installed packages
declare -A FAILED_PACKAGES=()        # Tracks failed installations
declare -A SYSTEM_CHANGES=()         # Tracks system configuration changes
declare -A INSTALLED_DEPS=()         # Tracks installed dependencies

# Logging configuration
LOGFILE="/tmp/environment_setup_$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$LOGFILE")
exec 2> >(tee -a "$LOGFILE" >&2)

################################################################################
# Utility Functions
################################################################################

# Function to print formatted section headers
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

# Function to print information messages
print_info() { 
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to log messages with timestamp
log_message() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOGFILE"
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

# Function to check if a command exists in PATH
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a file contains a specific line
file_contains() {
    grep -Fxq "$1" "$2" 2>/dev/null
}

# Function to track system changes
track_change() {
    SYSTEM_CHANGES[$1]="$2"
    log_message "CHANGE" "$1: $2"
}

# Function to install package if not already installed
install_package() {
    local package_name=$1
    if [ -n "${INSTALLED_DEPS[$package_name]}" ]; then
        return 0
    fi
    
    if ! dpkg -l | grep -q "^ii.*$package_name "; then
        sudo apt-get install -y "$package_name"
        INSTALLED_DEPS[$package_name]=1
        return $?
    fi
    return 0
}

# Function to install multiple packages
install_packages() {
    local packages=("$@")
    local to_install=()
    
    for pkg in "${packages[@]}"; do
        if [ -z "${INSTALLED_DEPS[$pkg]}" ] && ! dpkg -l | grep -q "^ii.*$pkg "; then
            to_install+=("$pkg")
            INSTALLED_DEPS[$pkg]=1
        fi
    done
    
    if [ ${#to_install[@]} -gt 0 ]; then
        sudo apt-get install -y "${to_install[@]}"
        return $?
    fi
    return 0
}
################################################################################
# System Verification Functions
################################################################################

# Function to check system requirements
check_system_requirements() {
    print_section "Checking System Requirements"
    
    # Check disk space (5GB minimum)
    local required_space=5120
    local available_space=$(df -m / | awk 'NR==2 {print $4}')
    
    if [ $available_space -lt $required_space ]; then
        print_error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        exit 1
    fi
    print_success "Disk space check passed"
    
    # Check sudo privileges
    if [ "$(id -u)" -eq 0 ]; then
        print_error "Please run this script as a normal user (not root)"
        print_info "The script will ask for sudo password when needed"
        exit 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        print_error "Script requires sudo privileges"
        exit 1
    fi
    print_success "Privilege check passed"
    
    # Verify Ubuntu version
    if ! lsb_release -a 2>/dev/null | grep -q "Ubuntu 22.04"; then
        print_warning "This script is optimized for Ubuntu 22.04 LTS"
        print_info "Some features might not work as expected on other versions"
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
            track_change "PATH" "Added $dir"
        fi
    done
    
    # Install bash-completion if needed
    if ! dpkg -l | grep -q bash-completion; then
        install_package "bash-completion"
    fi
    
    # Configure kubectl bash completion if kubectl is available
    if command_exists kubectl; then
        if ! grep -q "kubectl completion bash" ~/.bashrc; then
            kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
            echo 'source <(kubectl completion bash)' >>~/.bashrc
            print_success "Added kubectl completion to ~/.bashrc"
            track_change "Shell Configuration" "Added kubectl completion"
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
            track_change "Shell Configuration" "Added Azure CLI completion"
        else
            print_info "Azure CLI completion already configured"
        fi
    fi
    
    # Configure PowerShell completion if available
    if command_exists pwsh; then
        if ! grep -q "Register-ArgumentCompleter -Native -CommandName pwsh" ~/.bashrc; then
            echo 'Register-ArgumentCompleter -Native -CommandName pwsh -ScriptBlock {
                param($commandName, $wordToComplete, $cursorPosition)
                pwsh -NoProfile -Command {
                    param($wordToComplete)
                    Get-Command "$wordToComplete*" | Select-Object -ExpandProperty Name
                } -Args $wordToComplete
            }' | sudo tee /etc/bash_completion.d/pwsh > /dev/null
            print_success "Added PowerShell completion to ~/.bashrc"
            track_change "Shell Configuration" "Added PowerShell completion"
        else
            print_info "PowerShell completion already configured"
        fi
    fi
    
    # Verify KUBECONFIG environment variable
    if [ -f ~/.kube/config ]; then
        export KUBECONFIG=~/.kube/config
        print_success "KUBECONFIG set to ~/.kube/config"
        track_change "Environment" "Set KUBECONFIG"
    fi
}

# Function to configure system settings
configure_system_settings() {
    print_section "Configuring System Settings"
    
    local SYSCTL_SETTINGS=(
        "fs.inotify.max_user_instances=8192"
        "fs.inotify.max_user_watches=524288"
        "fs.file-max=100000"
    )
    
    # Create backup of sysctl.conf if it exists
    if [ -f /etc/sysctl.conf ] && [ ! -f /etc/sysctl.conf.bak ]; then
        sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak
        track_change "System Configuration" "Created sysctl.conf backup"
    fi
    
    # Apply settings
    for setting in "${SYSCTL_SETTINGS[@]}"; do
        if ! file_contains "$setting" /etc/sysctl.conf; then
            echo "$setting" | sudo tee -a /etc/sysctl.conf > /dev/null
            track_change "System Setting" "Added $setting"
        else
            print_info "System setting $setting already configured"
        fi
    done
    
    # Apply changes
    if ! sudo sysctl -p; then
        print_error "Failed to apply system settings"
        return 1
    fi
    
    print_success "System settings applied successfully"
    return 0
}
################################################################################
# Package Manager Installation Functions
################################################################################

# Function to install and configure Git
install_git() {
    print_section "Installing and Configuring Git"
    
    if ! command_exists git; then
        print_info "Installing Git from official repository"
        install_package "git"
        
        # Configure Git only if installation was successful
        if command_exists git; then
            git config --global credential.helper cache
            git config --global credential.helper 'cache --timeout=3600'
            git config --global init.defaultBranch main
            
            track_change "Git Configuration" "Configured credential helper and default branch"
            log_message "INFO" "Git installed and configured successfully"
        else
            log_error "Git installation failed"
            return 1
        fi
    else
        SKIPPED_PACKAGES["Git"]="Already installed"
        print_info "Git already installed"
        
        # Update Git configurations if needed
        if ! git config --global credential.helper &>/dev/null; then
            git config --global credential.helper cache
            git config --global credential.helper 'cache --timeout=3600'
            track_change "Git Configuration" "Updated credential helper"
        fi
    fi
}

# Function to install and configure Snapd
install_snapd() {
    print_section "Installing and Configuring Snapd"
    
    if ! command_exists snap; then
        print_info "Installing Snapd package manager"
        install_package "snapd"
        
        if [ $? -eq 0 ]; then
            # Enable and start snapd services
            sudo systemctl enable --now snapd.socket
            sudo systemctl start snapd.service
            
            # Create snap symbolic link
            sudo ln -sf /var/lib/snapd/snap /snap
            
            track_change "Snapd Installation" "Installed and configured snapd service"
            log_message "INFO" "Snapd installed and configured successfully"
            
            # Wait for service initialization
            print_info "Waiting for snapd service to initialize..."
            sleep 10
        else
            log_error "Snapd installation failed"
            return 1
        fi
    else
        SKIPPED_PACKAGES["Snapd"]="Already installed"
        print_info "Snapd already installed"
    fi
}

# Function to install and configure Homebrew
install_homebrew() {
    print_section "Installing Homebrew"
    
    if ! command_exists brew; then
        print_info "Installing Homebrew dependencies"
        local brew_deps=("build-essential" "procps" "curl" "file" "git")
        install_packages "${brew_deps[@]}"
        
        if [ $? -eq 0 ]; then
            # Install Homebrew
            print_info "Downloading and installing Homebrew..."
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
                print_error "Homebrew installation failed"
                return 1
            }
            
            # Configure Homebrew PATH
            if [ -d "/home/linuxbrew/.linuxbrew" ]; then
                echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$HOME/.bashrc"
                eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
                track_change "Homebrew Installation" "Installed and added to PATH"
                check_status "Homebrew" $?
                log_message "INFO" "Homebrew installed successfully"
            else
                print_error "Homebrew installation directory not found"
                FAILED_PACKAGES["Homebrew"]="Installation failed"
                log_message "ERROR" "Homebrew installation failed"
                return 1
            fi
        else
            print_error "Failed to install Homebrew dependencies"
            return 1
        fi
    else
        SKIPPED_PACKAGES["Homebrew"]="Already installed"
        print_info "Homebrew already installed"
    fi
}

################################################################################
# Development Tools Installation Functions
################################################################################

# Function to setup VS Code repository
setup_vscode() {
    print_section "Setting up VS Code Repository"
    if ! command_exists code; then
        # Install required dependencies if not already installed
        install_packages "gpg" "apt-transport-https"
        
        # Setup VS Code repository
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
        sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
            sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
        rm -f packages.microsoft.gpg
        track_change "VS Code Repository" "Added"
        
        # Update package lists after adding repository
        sudo apt-get update
    else
        SKIPPED_PACKAGES["VS Code"]="Already installed"
        print_info "VS Code repository already configured"
    fi
}

# Function to install PowerShell
install_powershell() {
    print_section "Installing PowerShell"
    if ! command_exists pwsh; then
        # Install prerequisites
        install_packages "wget" "apt-transport-https" "software-properties-common"
        
        # Download and install Microsoft repository
        wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
        if [ -f packages-microsoft-prod.deb ]; then
            sudo dpkg -i packages-microsoft-prod.deb
            rm packages-microsoft-prod.deb
            
            # Update package list and install PowerShell
            sudo apt-get update
            install_package "powershell"
            
            # Verify installation
            if command_exists pwsh; then
                local version=$(pwsh --version)
                check_status "PowerShell" $?
                track_change "PowerShell Installation" "Version: $version"
                log_message "INFO" "PowerShell installed successfully: $version"
            else
                log_error "PowerShell installation verification failed"
                FAILED_PACKAGES["PowerShell"]="Installation verification failed"
            fi
        else
            log_error "Failed to download Microsoft repository package"
            FAILED_PACKAGES["PowerShell"]="Repository setup failed"
        fi
    else
        SKIPPED_PACKAGES["PowerShell"]="Already installed"
        print_info "PowerShell already installed"
    fi
}
################################################################################
# Azure CLI and Arc Installation
################################################################################

# Function to setup Azure CLI and Arc
setup_azure() {
    print_section "Setting up Azure CLI Repository"
    if ! command_exists az; then
        # Install prerequisites
        install_packages "curl" "apt-transport-https" "lsb-release" "gnupg"
        
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
        install_package "azure-cli"
        check_status "Azure CLI" $?
        
        # Configure Azure CLI extension settings
        az config set extension.use_dynamic_install=yes_without_prompt &>/dev/null
        az config set extension.dynamic_install.allow_preview=true &>/dev/null
        
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
}

################################################################################
# Kubernetes Tools Installation
################################################################################

# Function to setup and configure K3s
setup_k3s() {
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
        
        # Wait for node to be ready
        local max_attempts=30
        local attempt=1
        while [ $attempt -le $max_attempts ]; do
            if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
                print_success "kubectl configured successfully"
                track_change "kubectl Configuration" "Completed"
                break
            fi
            print_info "Waiting for node to be ready (attempt $attempt of $max_attempts)..."
            sleep 10
            ((attempt++))
        done
        
        if [ $attempt -gt $max_attempts ]; then
            print_error "kubectl configuration failed - node not ready"
            FAILED_PACKAGES["kubectl configuration"]="Failed to configure access"
            return 1
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
}

# Function to setup Kubernetes tools repository
setup_kubernetes_tools() {
    print_section "Setting up Kubernetes Tools"
    if ! command_exists kubectl; then
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
            sudo tee /etc/apt/sources.list.d/kubernetes.list
        sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
        track_change "Kubernetes Repository" "Added"
        
        # Update package lists after adding repository
        sudo apt-get update
    else
        SKIPPED_PACKAGES["kubectl"]="Already installed"
        print_info "Kubernetes tools already configured"
    fi
}

# Function to setup Helm repository
setup_helm() {
    print_section "Setting up Helm Repository"
    if ! command_exists helm; then
        curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
            sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
        track_change "Helm Repository" "Added"
        
        # Update package lists after adding repository
        sudo apt-get update
    else
        SKIPPED_PACKAGES["Helm"]="Already installed"
        print_info "Helm repository already configured"
    fi
}

# Function to install K9s
install_k9s() {
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
}

################################################################################
# Monitoring Tools Installation
################################################################################

# Function to install MQTT-related tools
install_mqtt_tools() {
    print_section "Installing MQTT Tools"
    
    # Install Mosquitto clients
    if ! command_exists mosquitto_pub || ! command_exists mosquitto_sub; then
        print_info "Installing Mosquitto clients"
        install_package "mosquitto-clients"
        check_status "Mosquitto Clients" $?
        track_change "Mosquitto Clients" "Installed successfully"
    else
        SKIPPED_PACKAGES["Mosquitto Clients"]="Already installed"
        print_info "Mosquitto clients already installed"
    fi
    
    # Install MQTT Explorer
    if ! dpkg -l | grep -q mqtt-explorer; then
        print_info "Installing MQTT Explorer dependencies"
        install_packages "libgtk-3-0" "libnss3" "libxss1" "libxtst6" "xdg-utils" \
                        "libatspi2.0-0" "libsecret-1-0" "libgbm1" "libasound2t64" \
                        "libatk-bridge2.0-0"
        
        MQTT_EXPLORER_VERSION="0.4.0-beta.6"
        MQTT_DEB="MQTT-Explorer.deb"
        print_info "Downloading MQTT Explorer ${MQTT_EXPLORER_VERSION}"
        
        if wget -q --show-progress "https://github.com/thomasnordquist/MQTT-Explorer/releases/download/v${MQTT_EXPLORER_VERSION}/mqtt-explorer_${MQTT_EXPLORER_VERSION}_amd64.deb" -O "${MQTT_DEB}"; then
            print_success "Download completed"
            
            if sudo dpkg -i "${MQTT_DEB}"; then
                print_success "Initial installation successful"
            else
                print_info "Fixing dependencies..."
                sudo apt-get install -f -y
                sudo dpkg -i "${MQTT_DEB}"
            fi
            
            rm "${MQTT_DEB}"
            
            if dpkg -l | grep -q mqtt-explorer; then
                check_status "MQTT Explorer" 0
                track_change "MQTT Explorer Installation" "Version ${MQTT_EXPLORER_VERSION}"
            else
                check_status "MQTT Explorer" 1
                print_error "MQTT Explorer installation failed"
            fi
        else
            print_error "Failed to download MQTT Explorer"
            FAILED_PACKAGES["MQTT Explorer"]="Download failed"
            log_message "ERROR" "Failed to download MQTT Explorer"
        fi
    else
        SKIPPED_PACKAGES["MQTT Explorer"]="Already installed"
        print_info "MQTT Explorer already installed"
    fi
}
################################################################################
# Summary and Report Functions
################################################################################

# Function to print installation summary
print_summary() {
    print_section "Installation Summary"
    
    # Print successfully installed packages
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n${GREEN}Successfully Installed:${NC}"
        for pkg in "${!INSTALLED_PACKAGES[@]}"; do
            echo "  ✔ $pkg: ${INSTALLED_PACKAGES[$pkg]}"
        done
    fi
    
    # Print skipped packages
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
    
    # Print system changes
    if [ ${#SYSTEM_CHANGES[@]} -gt 0 ]; then
        echo -e "\n${BLUE}System Changes:${NC}"
        for change in "${!SYSTEM_CHANGES[@]}"; do
            echo "  • $change: ${SYSTEM_CHANGES[$change]}"
        done
    fi
}

# Function to print tool information and usage
print_tool_information() {
    print_section "Tool Information"
    
    echo -e "${YELLOW}Installed Tools and Usage:${NC}"
    
    echo -e "\n1. Kubernetes Tools:"
    echo "   - kubectl: Kubernetes command-line tool"
    echo "   - helm: Kubernetes package manager"
    echo "   - k3s: Lightweight Kubernetes"
    echo "   - K9s: Terminal UI (Launch: k9s, Exit: Ctrl+C or :quit)"
    
    echo -e "\n2. Monitoring Tools:"
    echo "   - MQTT Explorer: GUI MQTT Client"
    echo "     Launch: mqtt-explorer"
    echo "     Default port: 1883"
    echo "   - Mosquitto Clients: Command-line MQTT tools"
    echo "     Publish: mosquitto_pub -h localhost -t topic -m 'message'"
    echo "     Subscribe: mosquitto_sub -h localhost -t topic"
    
    echo -e "\n3. Development Tools:"
    echo "   - VS Code: Launch with 'code'"
    echo "   - Git: Configured with credential cache (1-hour timeout)"
    echo "   - PowerShell: Launch with 'pwsh'"
    echo "   - Azure CLI: Command set 'az'"
    
    echo -e "\n4. Package Managers:"
    echo "   - Snapd: snap install <package>"
    echo "   - Homebrew: brew install <package>"
    echo "   - APT: apt install <package>"
    
    echo -e "\n5. Shell Completions Added:"
    echo "   - kubectl completion"
    echo "   - Azure CLI completion"
    echo "   - PowerShell completion"
}

# Function to perform cleanup operations
cleanup() {
    local exit_code=$?
    
    # Remove any temporary files
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    
    # Log final status
    if [ $exit_code -eq 0 ]; then
        log_message "INFO" "Script completed successfully"
    else
        log_message "ERROR" "Script failed with exit code $exit_code"
    fi
    
    # Print final message
    if [ $exit_code -eq 0 ]; then
        print_success "Setup completed successfully"
    else
        print_error "Setup completed with errors"
    fi
    
    echo -e "\n${BLUE}Log file location: $LOGFILE${NC}"
    echo -e "${YELLOW}To apply all changes, please run: source ~/.bashrc${NC}"
}

################################################################################
# Main Execution
################################################################################

main() {
    local start_time=$(date +%s)
    log_message "INFO" "Starting installation script"
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    trap cleanup EXIT
    
    # Set non-interactive frontend
    export DEBIAN_FRONTEND=noninteractive
    
    # Perform initial checks
    check_system_requirements || exit 1
    
    # Update system packages
    print_section "Updating System Packages"
    if ! sudo apt-get update; then
        print_error "Failed to update package lists"
        exit 1
    fi
    track_change "System" "Updated package lists"
    
    # Install basic dependencies
    print_section "Installing Basic Dependencies"
    local BASIC_DEPS=(
        "wget"
        "gpg"
        "apt-transport-https"
        "ca-certificates"
        "curl"
        "gnupg"
        "lsb-release"
    )
    install_packages "${BASIC_DEPS[@]}" || {
        print_error "Failed to install basic dependencies"
        exit 1
    }
    
    # Install and configure components
    local install_functions=(
        "install_git"
        "install_snapd"
        "install_homebrew"
        "install_powershell"
        "setup_vscode"
        "setup_azure"
        "setup_k3s"
        "setup_kubernetes_tools"
        "setup_helm"
        "install_k9s"
        "install_mqtt_tools"
    )
    
    for func in "${install_functions[@]}"; do
        if ! $func; then
            print_error "Failed to execute $func"
            log_message "ERROR" "Function $func failed"
            # Continue with other installations
        fi
    done
    
    # Update package lists for all package managers
    print_section "Updating Package Lists"
    sudo apt-get update
    if command_exists snap; then
        sudo snap refresh
    fi
    if command_exists brew; then
        brew update
    fi
    
    # Install additional tools
    print_section "Installing Additional Tools"
    local TOOLS="code azure-cli kubectl helm jq"
    for tool in $TOOLS; do
        if ! command_exists $tool; then
            install_package "$tool"
        else
            SKIPPED_PACKAGES[$tool]="Already installed"
            print_info "$tool already installed"
        fi
    done
    
    # Configure system settings
    configure_system_settings
    
    # Verify and load environment configurations
    verify_and_load_environment
    
    # Print summaries
    print_summary
    print_tool_information
    
    # Calculate and log execution time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_message "INFO" "Script execution completed in ${duration} seconds"
    
    return 0
}

################################################################################
# Script Entry Point
################################################################################

# Ensure script is run with bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with bash"
    exit 1
fi

# Check for required commands
REQUIRED_COMMANDS=(az jq kubectl)
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command_exists $cmd &>/dev/null; then
        MISSING_COMMANDS+=($cmd)
    fi
done

if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    echo "Error: Required commands not found: ${MISSING_COMMANDS[*]}"
    echo "Please install missing commands and try again"
    exit 1
fi

# Execute main function
main
exit $?