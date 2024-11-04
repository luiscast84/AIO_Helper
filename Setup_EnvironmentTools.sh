#!/bin/bash
#########################################################################
# Script: Complete Environment Setup for Ubuntu 22.04 LTS
# Description: Automated setup script for:
#   - Kubernetes tools (K3s, kubectl, Helm, K9s)
#   - Azure CLI and Arc extensions
#   - Development tools (VS Code, Git)
#   - Package managers (Snapd, Homebrew)
#   - Monitoring tools (MQTT Explorer)
# Version: 3.0
# Last Updated: 2024-11-04
#########################################################################

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arrays to track installation status
declare -A INSTALLED_PACKAGES=()     # Tracks newly installed packages
declare -A SKIPPED_PACKAGES=()       # Tracks already installed packages
declare -A FAILED_PACKAGES=()        # Tracks failed installations
declare -A SYSTEM_CHANGES=()         # Tracks system configuration changes

# Logging configuration
LOGFILE="/tmp/environment_setup_$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$LOGFILE")
exec 2> >(tee -a "$LOGFILE" >&2)

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

# Function to print information messages
print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to log messages
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

# Function to check if a command exists
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
}
# Function to check system requirements
check_system_requirements() {
    print_section "Checking System Requirements"
    
    # Check disk space
    local required_space=5120  # 5GB in MB
    local available_space=$(df -m / | awk 'NR==2 {print $4}')
    
    if [ $available_space -lt $required_space ]; then
        print_error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        exit 1
    fi
    print_success "Disk space check passed"
    
    # Check sudo privileges
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        print_error "Script requires sudo privileges"
        exit 1
    fi
    print_success "Privilege check passed"
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

# Function to print installation summary
print_summary() {
    print_section "Installation Summary"
    
    # Print successfully installed packages
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${GREEN}Successfully Installed:${NC}"
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
# Function to install Git
install_git() {
    print_section "Installing and Configuring Git"
    
    if ! command_exists git; then
        print_info "Installing Git from official repository"
        sudo apt-get install -y git
        check_status "Git" $?
        
        # Configure Git
        git config --global credential.helper cache
        git config --global credential.helper 'cache --timeout=3600'
        git config --global init.defaultBranch main
        
        track_change "Git Configuration" "Configured credential helper and default branch"
        log_message "INFO" "Git installed and configured successfully"
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

# Function to install Snapd
install_snapd() {
    print_section "Installing and Configuring Snapd"
    
    if ! command_exists snap; then
        print_info "Installing Snapd package manager"
        sudo apt-get install -y snapd
        check_status "Snapd" $?
        
        # Enable snapd services
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
        SKIPPED_PACKAGES["Snapd"]="Already installed"
        print_info "Snapd already installed"
    fi
}

# Function to install Homebrew
install_homebrew() {
    print_section "Installing Homebrew"
    
    if ! command_exists brew; then
        print_info "Installing Homebrew dependencies"
        sudo apt-get install -y build-essential procps curl file git
        
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
        SKIPPED_PACKAGES["Homebrew"]="Already installed"
        print_info "Homebrew already installed"
    fi
}

# Function to setup VS Code repository and package
setup_vscode() {
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
}

# Function to setup Azure CLI and Arc
setup_azure() {
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
}
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

# Function to install MQTT Explorer
install_mqtt_explorer() {
    print_section "Installing MQTT Explorer"
    if ! dpkg -l | grep -q mqtt-explorer; then
        print_info "Installing MQTT Explorer dependencies"
        # Updated dependencies for Ubuntu 22.04 with specific audio package
        sudo apt-get install -y \
            libgtk-3-0 \
            libnss3 \
            libxss1 \
            libxtst6 \
            xdg-utils \
            libatspi2.0-0 \
            libsecret-1-0 \
            libgbm1 \
            libasound2t64 \
            libatk-bridge2.0-0

        MQTT_EXPLORER_VERSION="0.4.0-beta.6"
        MQTT_DEB="MQTT-Explorer.deb"
        print_info "Downloading MQTT Explorer ${MQTT_EXPLORER_VERSION}"
        
        # Using the correct package URL with updated version
        if wget -q --show-progress "https://github.com/thomasnordquist/MQTT-Explorer/releases/download/v${MQTT_EXPLORER_VERSION}/mqtt-explorer_${MQTT_EXPLORER_VERSION}_amd64.deb" -O "${MQTT_DEB}"; then
            print_success "Download completed"
            
            # Install the package and handle dependencies
            if sudo dpkg -i "${MQTT_DEB}"; then
                print_success "Initial installation successful"
            else
                print_info "Fixing dependencies..."
                sudo apt-get install -f -y
                sudo dpkg -i "${MQTT_DEB}"
            fi
            
            # Cleanup
            rm "${MQTT_DEB}"
            
            if dpkg -l | grep -q mqtt-explorer; then
                check_status "MQTT Explorer" 0
                track_change "MQTT Explorer Installation" "Version ${MQTT_EXPLORER_VERSION}"
                print_success "MQTT Explorer installed successfully"
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
# Main script execution
print_section "Starting Environment Setup"
log_message "INFO" "Starting installation script"

# Set non-interactive frontend
export DEBIAN_FRONTEND=noninteractive

# Check system requirements
check_system_requirements

# Update system packages
print_section "Updating System Packages"
if sudo apt-get update; then
    track_change "APT Update" "Completed successfully"
else
    print_error "APT update failed"
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

# Install and configure all components
install_git
install_snapd
install_homebrew
setup_vscode
setup_azure
setup_k3s
setup_kubernetes_tools
setup_helm
install_k9s
install_mqtt_explorer

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
TOOLS="code azure-cli kubectl helm jq"
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

# Print final instructions and tool information
print_section "Final Steps"
echo -e "${YELLOW}To complete the setup, please run:${NC}"
echo "source ~/.bashrc"

print_section "Tool Information"
echo -e "${YELLOW}Installed Tools:${NC}"
echo "1. K9s - Kubernetes CLI To Manage Your Clusters In Style"
echo "   - Launch with: k9s"
echo "   - Exit with: Ctrl+C or :quit"
echo
echo "2. MQTT Explorer - MQTT Client for debugging"
echo "   - Launch from applications menu or run: mqtt-explorer"
echo "   - Default port for MQTT connections: 1883"
echo
echo "3. Package Managers:"
echo "   - Snapd: snap install <package>"
echo "   - Homebrew: brew install <package>"
echo "   - APT: apt install <package>"
echo
echo "4. Kubernetes Tools:"
echo "   - kubectl: Kubernetes command-line tool"
echo "   - helm: Kubernetes package manager"
echo "   - k3s: Lightweight Kubernetes"
echo
echo "5. Development Tools:"
echo "   - VS Code: code"
echo "   - Git: Configured with credential cache"
echo "   - Azure CLI: az"

echo -e "${BLUE}Log file location: $LOGFILE${NC}"
log_message "INFO" "Installation completed"

print_success "Environment setup completed successfully"
