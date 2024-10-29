#!/bin/bash

################################################################################
# Azure Arc Resource Setup Script
#
# This script automates the setup of Azure Arc-enabled Kubernetes cluster and
# associated resources. It handles:
# - Environment verification and setup
# - Azure authentication and subscription management
# - Resource group management
# - Provider registration
# - Kubernetes cluster configuration and Arc enablement
# - Storage and Key Vault creation
################################################################################

# Color codes for pretty output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
readonly SCRIPT_START_TIME=$(date +%s)
readonly RESOURCE_GROUP="LAB460"  # Fixed resource group name

# Arrays to track status
declare -A ACTION_TIMES
declare -A INSTALLED_PACKAGES
declare -A SKIPPED_PACKAGES
declare -A FAILED_PACKAGES
declare -A SYSTEM_CHANGES

################################################################################
# Utility Functions
################################################################################

# Function to print formatted section headers
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Function to print info messages
log_info() { 
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to print success messages
log_success() { 
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to print warning messages
log_warning() { 
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to print error messages
log_error() { 
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to measure execution time of actions
time_action() {
    local start_time=$(date +%s)
    local action_name="$1"
    shift
    "$@"
    local status=$?
    local end_time=$(date +%s)
    ACTION_TIMES["$action_name"]=$((end_time - start_time))
    return $status
}

# Function to format text (lowercase and remove spaces)
format_text() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '
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

# Function to check command status and track results
check_status() {
    local command_name=$1
    local status=$2
    if [ $status -eq 0 ]; then
        INSTALLED_PACKAGES[$command_name]="Installed successfully"
        log_success "$command_name completed successfully"
        return 0
    else
        FAILED_PACKAGES[$command_name]="Installation failed"
        log_error "$command_name failed"
        return 1
    fi
}

################################################################################
# System Verification Functions
################################################################################

# Function to check system requirements
check_system_requirements() {
    print_section "Checking System Requirements"
    
    # Check disk space (require 5GB free)
    local required_space=5120  # 5GB in MB
    local available_space=$(df -m / | awk 'NR==2 {print $4}')
    
    if [ $available_space -lt $required_space ]; then
        log_error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        exit 1
    fi
    log_success "Disk space check passed"
    
    # Check sudo privileges
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        log_error "Script requires sudo privileges"
        exit 1
    fi
    log_success "Privilege check passed"
}

# Function to verify environment paths
verify_environment_paths() {
    print_section "Verifying Environment Paths"
    
    # Check and add necessary directories to PATH
    local dirs_to_check=("/usr/local/bin" "/usr/bin" "/usr/local/sbin")
    for dir in "${dirs_to_check[@]}"; do
        if [[ ":$PATH:" != *":$dir:"* ]]; then
            export PATH="$PATH:$dir"
            log_info "Added $dir to PATH"
        fi
    done
}

################################################################################
# Azure Authentication Functions
################################################################################

# Function to check Azure login status
check_azure_login() {
    print_section "Checking Azure Authentication"
    
    if az account show &>/dev/null; then
        log_success "Already logged into Azure"
        return 0
    else
        log_info "Azure login required. Opening browser..."
        time_action "Azure Login" az login || {
            log_error "Azure login failed"
            return 1
        }
    fi
}

# Function to get and validate subscription
get_subscription() {
    local current_sub=""
    
    # Try to get current subscription
    if current_sub=$(az account show --query id -o tsv 2>/dev/null); then
        log_info "Current subscription: $(az account show --query name -o tsv)"
        log_info "Subscription ID: $current_sub"
        SUBSCRIPTION_ID=$current_sub
        log_success "Using current subscription: $SUBSCRIPTION_ID"
        return 0
    else
        # If no current subscription, show available ones
        log_info "Available subscriptions:"
        az account list --query "[].{Name:name, ID:id, State:state}" -o table
        
        while true; do
            read -p "Enter Subscription ID: " SUBSCRIPTION_ID
            
            if az account show --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
                az account set --subscription "$SUBSCRIPTION_ID"
                log_success "Switched to subscription: $SUBSCRIPTION_ID"
                break
            else
                log_error "Invalid subscription ID. Please try again."
            fi
        done
    fi
}

################################################################################
# Resource Management Functions
################################################################################

# Function to check resource group existence and location
check_resource_group() {
    print_section "Checking Resource Group"
    
    log_info "Checking for resource group $RESOURCE_GROUP..."
    
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
        log_success "Found existing resource group $RESOURCE_GROUP in location: $LOCATION"
        return 0
    else
        log_warning "Resource group $RESOURCE_GROUP not found"
        get_location
        log_info "Creating resource group $RESOURCE_GROUP in $LOCATION..."
        time_action "Create Resource Group" az group create --name "$RESOURCE_GROUP" --location "$LOCATION" || {
            log_error "Failed to create resource group"
            return 1
        }
    fi
}

# Function to get and validate Azure location
get_location() {
    print_section "Setting Azure Location"
    
    log_info "Available Azure locations:"
    az account list-locations --query "[].name" -o table
    
    while true; do
        read -p "Enter Azure location: " LOCATION
        LOCATION=$(format_text "$LOCATION")
        if az account list-locations --query "[?name=='$LOCATION']" --output tsv &>/dev/null; then
            break
        else
            log_error "Invalid location. Please try again."
        fi
    done
}

################################################################################
# Azure Provider Registration Functions
################################################################################

# Function to wait for provider registration
wait_for_provider_registration() {
    local provider=$1
    local max_attempts=30
    local attempt=1
    local wait_time=10

    log_info "Waiting for $provider registration to complete..."
    
    while [ $attempt -le $max_attempts ]; do
        local status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
        
        if [ "$status" == "Registered" ]; then
            log_success "$provider registration completed"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts: $provider is in $status state. Waiting $wait_time seconds..."
        sleep $wait_time
        ((attempt++))
    done

    log_error "$provider registration did not complete in time"
    return 1
}

# Function to register Azure providers
register_providers() {
    print_section "Registering Azure Providers"
    
    local providers=(
        "Microsoft.ExtendedLocation"
        "Microsoft.Kubernetes"
        "Microsoft.KubernetesConfiguration"
        "Microsoft.IoTOperations"
        "Microsoft.DeviceRegistry"
        "Microsoft.SecretSyncController"
    )
    
    for provider in "${providers[@]}"; do
        log_info "Checking provider: $provider"
        local status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv 2>/dev/null)
        
        if [ "$status" != "Registered" ]; then
            log_info "Registering provider: $provider"
            if ! time_action "Register $provider" az provider register -n "$provider"; then
                log_error "Failed to start registration for $provider"
                return 1
            fi
            
            # Wait for registration to complete
            if ! wait_for_provider_registration "$provider"; then
                log_error "Failed to register $provider"
                return 1
            fi
        else
            log_info "$provider already registered"
        fi
    done
    
    log_success "All providers successfully registered"
    return 0
}

################################################################################
# Kubernetes Setup and Configuration Functions
################################################################################

# Function to install kubectl
install_kubectl() {
    print_section "Installing kubectl"
    
    # Remove any existing kubectl installation
    if command -v kubectl &>/dev/null; then
        log_info "Removing existing kubectl installation..."
        sudo apt-get remove -y kubectl &>/dev/null
    fi
    
    # Add Google's apt repository and key
    log_info "Adding Kubernetes repository..."
    sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list
    
    # Update apt and install kubectl
    log_info "Installing kubectl..."
    sudo apt-get update
    sudo apt-get install -y kubectl
    
    # Verify installation
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl installation failed"
        return 1
    fi
    
    # Verify kubectl can run
    if ! kubectl version --client &>/dev/null; then
        log_error "kubectl verification failed"
        return 1
    fi
    
    log_success "kubectl installed successfully"
    return 0
}

# Function to get resource names
get_resource_names() {
    print_section "Getting Resource Names"
    
    # Get cluster name
    while true; do
        read -p "Enter cluster name (lowercase, no spaces): " CLUSTER_NAME
        CLUSTER_NAME=$(format_text "$CLUSTER_NAME")
        if [[ $CLUSTER_NAME =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
            break
        else
            log_error "Invalid cluster name. Use lowercase letters, numbers, and hyphens."
        fi
    done
    
    # Get storage account name
    while true; do
        read -p "Enter storage account base name: " storage_base
        STORAGE_NAME=$(format_text "${storage_base}st")
        if [[ $STORAGE_NAME =~ ^[a-z0-9]{3,24}$ ]]; then
            break
        else
            log_error "Invalid storage account name. Use 3-24 lowercase letters and numbers."
        fi
    done
    
    # Get key vault name
    while true; do
        read -p "Enter key vault base name: " kv_base
        AKV_NAME=$(format_text "${kv_base}akv")
        if [[ $AKV_NAME =~ ^[a-z0-9-]{3,24}$ ]]; then
            break
        else
            log_error "Invalid key vault name. Use 3-24 lowercase letters, numbers, and hyphens."
        fi
    done
}

# Function to verify kubeconfig setup
verify_kubeconfig() {
    print_section "Verifying Kubernetes Configuration"
    
    # Check if k3s is running
    if ! systemctl is-active --quiet k3s; then
        log_info "K3s service not running. Starting k3s..."
        sudo systemctl start k3s
        sleep 10  # Wait for k3s to start
    fi
    
    # Ensure k3s.yaml exists
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
        log_error "k3s configuration file not found at /etc/rancher/k3s/k3s.yaml"
        return 1
    fi
    
    # Create .kube directory if it doesn't exist
    mkdir -p ~/.kube
    
    # Copy and set proper permissions for kubeconfig
    log_info "Setting up kubeconfig..."
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    chmod 600 ~/.kube/config
    
    # Set KUBECONFIG environment variable
    export KUBECONFIG=~/.kube/config
    
    # Verify kubectl can connect
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Unable to connect to Kubernetes cluster"
        return 1
    fi
    
    log_success "Kubernetes configuration verified successfully"
    return 0
}

# Function to setup connected kubernetes
setup_connectedk8s() {
    print_section "Setting up Connected Kubernetes"
    
    # Install kubectl if not present
    if ! command -v kubectl &>/dev/null; then
        if ! install_kubectl; then
            log_error "Failed to install kubectl"
            return 1
        fi
    fi
    
    # Verify kubeconfig
    if ! verify_kubeconfig; then
        log_error "Failed to verify Kubernetes configuration"
        return 1
    fi
    
    # Add extension if not present
    if ! az extension show --name connectedk8s &>/dev/null; then
        time_action "Add connectedk8s extension" az extension add --upgrade --name connectedk8s || {
            log_error "Failed to add connectedk8s extension"
            return 1
        }
    fi
    
    # Connect cluster
    log_info "Connecting cluster to Azure Arc..."
    time_action "Connect Kubernetes cluster" az connectedk8s connect \
        --name "$CLUSTER_NAME" \
        -l "$LOCATION" \
        --resource-group "$RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --enable-oidc-issuer \
        --enable-workload-identity || {
        log_error "Failed to connect Kubernetes cluster"
        log_info "Checking cluster status..."
        kubectl cluster-info
        return 1
    }
    
    # Get OIDC Issuer URL
    ISSUER_URL_ID=$(az connectedk8s show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --query oidcIssuerProfile.issuerUrl \
        --output tsv)
        
    if [ -z "$ISSUER_URL_ID" ]; then
        log_error "Failed to get OIDC Issuer URL"
        return 1
    fi
    
    log_success "Successfully connected to Azure Arc"
    return 0
}

# Function to configure k3s
configure_k3s() {
    print_section "Configuring k3s"
    
    # Check if OIDC URL is available
    if [ -z "$ISSUER_URL_ID" ]; then
        log_error "OIDC Issuer URL not available"
        return 1
    fi
    
    # Create k3s configuration
    log_info "Updating k3s configuration..."
    {
        echo "kube-apiserver-arg:"
        echo " - service-account-issuer=$ISSUER_URL_ID"
        echo " - service-account-max-token-expiration=24h"
    } | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
    
    # Restart k3s and wait for it to be ready
    log_info "Restarting k3s..."
    sudo systemctl restart k3s
    sleep 10
    
    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if kubectl get nodes | grep -q "Ready"; then
            log_success "Node is ready"
            break
        fi
        log_info "Attempt $attempt/$max_attempts: Waiting for node to be ready..."
        sleep 10
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log_error "Node did not become ready in time"
        return 1
    fi
    
    log_success "k3s configuration completed"
    return 0
}

################################################################################
# Azure Resource Creation Functions
################################################################################

# Function to create Azure resources
create_azure_resources() {
    print_section "Creating Azure Resources"
    
    # Create Key Vault
    log_info "Creating Key Vault $AKV_NAME..."
    local kvResult=""
    kvResult=$(time_action "Create Key Vault" az keyvault create \
        --enable-rbac-authorization \
        --name "$AKV_NAME" \
        --resource-group "$RESOURCE_GROUP" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "Failed to create Key Vault"
        return 1
    fi
    
    AKV_ID=$(echo "$kvResult" | jq -r '.id')
    if [ -z "$AKV_ID" ]; then
        log_error "Failed to get Key Vault ID"
        return 1
    fi
    
    # Create Storage Account
    log_info "Creating Storage Account $STORAGE_NAME..."
    if ! time_action "Create Storage Account" az storage account create \
        --name "$STORAGE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --enable-hierarchical-namespace; then
        log_error "Failed to create storage account"
        return 1
    fi
    
    log_success "Azure resources created successfully"
    return 0
}

################################################################################
# Summary and Configuration Functions
################################################################################

# Function to print execution summary
print_summary() {
    local end_time=$(date +%s)
    local total_time=$((end_time - SCRIPT_START_TIME))
    
    print_section "Execution Summary"
    
    echo -e "\n${GREEN}Configuration:${NC}"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Storage Account: $STORAGE_NAME"
    echo "Key Vault: $AKV_NAME"
    echo "Key Vault ID: $AKV_ID"
    
    echo -e "\n${YELLOW}Execution Times:${NC}"
    for action in "${!ACTION_TIMES[@]}"; do
        printf "%-30s: %d seconds\n" "$action" "${ACTION_TIMES[$action]}"
    done
    echo "Total Execution Time: $total_time seconds"
    
    # Save configuration
    log_info "Saving configuration to azure_config.env..."
    cat > azure_config.env << EOF
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export LOCATION="$LOCATION"
export RESOURCE_GROUP="$RESOURCE_GROUP"
export CLUSTER_NAME="$CLUSTER_NAME"
export STORAGE_NAME="$STORAGE_NAME"
export AKV_NAME="$AKV_NAME"
export AKV_ID="$AKV_ID"
export ISSUER_URL_ID="$ISSUER_URL_ID"
EOF
    log_success "Configuration saved to azure_config.env"
}

################################################################################
# Main Execution Function
################################################################################

main() {
    log_info "Starting Azure setup script..."
    
    # Essential setup and verification
    check_system_requirements || exit 1
    verify_environment_paths || exit 1
    
    # Azure authentication and setup
    check_azure_login || exit 1
    get_subscription || exit 1
    check_resource_group || exit 1
    get_resource_names || exit 1
    
    # Show configuration before proceeding
    print_section "Configuration to be applied"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Storage Account: $STORAGE_NAME"
    echo "Key Vault: $AKV_NAME"
    
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    
    # Execute Azure operations with progress tracking
    local start_step=1
    local total_steps=4
    
    # Step 1: Register providers
    log_info "Step $start_step/$total_steps: Registering Azure providers"
    if ! register_providers; then
        log_error "Provider registration failed"
        exit 1
    fi
    
    # Step 2: Setup connected kubernetes
    log_info "Step $((start_step + 1))/$total_steps: Setting up connected Kubernetes"
    if ! setup_connectedk8s; then
        log_error "Kubernetes setup failed"
        exit 1
    fi
    
    # Step 3: Configure k3s
    log_info "Step $((start_step + 2))/$total_steps: Configuring k3s"
    if ! configure_k3s; then
        log_error "k3s configuration failed"
        exit 1
    fi
    
    # Step 4: Create Azure resources
    log_info "Step $((start_step + 3))/$total_steps: Creating Azure resources"
    if ! create_azure_resources; then
        log_error "Resource creation failed"
        exit 1
    fi
    
    # Print summary
    print_summary
    
    log_success "Setup completed successfully!"
    log_info "To load the configuration in a new session, run: source azure_config.env"
}

################################################################################
# Script Execution
################################################################################

# Ensure script is run with bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with bash"
    exit 1
fi

# Ensure required commands are available
for cmd in az jq kubectl; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: Required command '$cmd' not found"
        exit 1
    fi
done

# Execute main function
main

exit 0