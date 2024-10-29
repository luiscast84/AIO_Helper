#!/bin/bash

################################################################################
# Azure Arc Resource Setup Script
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

################################################################################
# Utility Functions
################################################################################

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

log_info() { 
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() { 
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() { 
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() { 
    echo -e "${RED}[ERROR]${NC} $1"
}

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

format_text() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

################################################################################
# Privilege Management
################################################################################

check_sudo_privileges() {
    print_section "Checking Sudo Privileges"
    
    if is_root; then
        log_error "Please run this script as a normal user (not root)"
        log_info "The script will ask for sudo password when needed"
        exit 1
    fi
    
    log_info "This script requires sudo privileges for:"
    echo "  - Installing system packages"
    echo "  - Configuring k3s"
    echo "  - Modifying system settings"
    echo -e "\nOther operations like Azure login will run as current user"
    
    if ! sudo -v; then
        log_error "Unable to get sudo privileges"
        exit 1
    fi
    
    # Keep sudo alive
    (while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null) &
    SUDO_KEEPER_PID=$!
    
    trap 'kill $SUDO_KEEPER_PID 2>/dev/null' EXIT
    
    log_success "Sudo privileges confirmed"
}

################################################################################
# Azure Authentication
################################################################################

check_azure_login() {
    print_section "Checking Azure Authentication"
    
    if ! command -v az >/dev/null 2>&1; then
        log_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    if az account show &>/dev/null; then
        log_info "Current Azure login information:"
        az account show --query "{Subscription:name,UserName:user.name,TenantID:tenantId}" -o table
        
        read -p "Continue with this Azure account? (Y/n): " use_current
        if [[ -z "$use_current" || "${use_current,,}" == "y"* ]]; then
            log_success "Using current Azure login"
            return 0
        fi
    fi
    
    log_info "Azure login required. Opening browser..."
    if ! az login --use-device-code; then
        log_error "Azure login failed"
        return 1
    fi
    
    log_info "Logged in successfully. Account information:"
    az account show --query "{Subscription:name,UserName:user.name,TenantID:tenantId}" -o table
    return 0
}
################################################################################
# Subscription Management
################################################################################

get_subscription() {
    print_section "Checking Subscription"
    
    # Try to get current subscription
    local current_sub
    if current_sub=$(az account show --query id -o tsv 2>/dev/null); then
        log_info "Current subscription: $(az account show --query name -o tsv)"
        log_info "Subscription ID: $current_sub"
        SUBSCRIPTION_ID=$current_sub
        log_success "Using current subscription: $SUBSCRIPTION_ID"
        return 0
    else
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
# Resource Group Management
################################################################################

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
        if ! az group create --name "$RESOURCE_GROUP" --location "$LOCATION"; then
            log_error "Failed to create resource group"
            return 1
        fi
    fi
}

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
# Resource Names Management
################################################################################

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
            # Check if storage account name is available
            if az storage account check-name --name "$STORAGE_NAME" --query "nameAvailable" -o tsv | grep -q "true"; then
                break
            else
                log_error "Storage account name '$STORAGE_NAME' is not available. Please choose another name."
            fi
        else
            log_error "Invalid storage account name. Use 3-24 lowercase letters and numbers."
        fi
    done
    
    # Get key vault name
    while true; do
        read -p "Enter key vault base name: " kv_base
        AKV_NAME=$(format_text "${kv_base}akv")
        if [[ $AKV_NAME =~ ^[a-z0-9-]{3,24}$ ]]; then
            # Check if key vault name is available
            if ! az keyvault name-exists --name "$AKV_NAME"; then
                break
            else
                log_error "Key vault name '$AKV_NAME' is not available. Please choose another name."
            fi
        else
            log_error "Invalid key vault name. Use 3-24 lowercase letters, numbers, and hyphens."
        fi
    done
}

################################################################################
# Provider Registration
################################################################################

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
            if ! az provider register -n "$provider"; then
                log_error "Failed to register $provider"
                return 1
            fi
            
            # Wait for registration
            log_info "Waiting for $provider registration..."
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
                if [ "$status" == "Registered" ]; then
                    break
                fi
                log_info "Attempt $attempt/$max_attempts: Provider status: $status"
                sleep 10
                ((attempt++))
            done
        else
            log_info "$provider already registered"
        fi
    done
    
    log_success "All providers successfully registered"
    return 0
}
################################################################################
# Kubernetes Setup
################################################################################

install_kubectl() {
    print_section "Installing kubectl"
    
    # Remove any existing kubectl installation
    if command -v kubectl &>/dev/null; then
        log_info "Removing existing kubectl installation..."
        sudo apt-get remove -y kubectl &>/dev/null
    fi
    
    # Add Kubernetes repository and key
    log_info "Adding Kubernetes repository..."
    if ! sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg; then
        log_error "Failed to download Kubernetes repository key"
        return 1
    fi
    
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    
    # Update apt and install kubectl
    log_info "Installing kubectl..."
    sudo apt-get update
    if ! sudo apt-get install -y kubectl; then
        log_error "Failed to install kubectl"
        return 1
    fi
    
    # Verify installation
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl installation failed"
        return 1
    fi
    
    log_success "kubectl installed successfully"
    return 0
}

verify_kubeconfig() {
    print_section "Verifying Kubernetes Configuration"
    
    # Check if k3s is running
    if ! systemctl is-active --quiet k3s; then
        log_info "K3s service not running. Starting k3s..."
        sudo systemctl start k3s
        sleep 10
    fi
    
    # Ensure k3s.yaml exists
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
        log_error "k3s configuration file not found at /etc/rancher/k3s/k3s.yaml"
        return 1
    fi
    
    # Set up kubeconfig
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    chmod 600 ~/.kube/config
    export KUBECONFIG=~/.kube/config
    
    # Verify kubectl can connect
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Unable to connect to Kubernetes cluster"
        return 1
    fi
    
    log_success "Kubernetes configuration verified successfully"
    return 0
}

setup_connectedk8s() {
    print_section "Setting up Connected Kubernetes"
    
    # Verify kubectl installation
    if ! command -v kubectl &>/dev/null; then
        log_info "kubectl not found, installing..."
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
        log_info "Adding connectedk8s extension..."
        if ! az extension add --upgrade --name connectedk8s; then
            log_error "Failed to add connectedk8s extension"
            return 1
        fi
    fi
    
    # Connect cluster
    log_info "Connecting cluster to Azure Arc..."
    if ! az connectedk8s connect \
        --name "$CLUSTER_NAME" \
        -l "$LOCATION" \
        --resource-group "$RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --enable-oidc-issuer \
        --enable-workload-identity; then
        log_error "Failed to connect Kubernetes cluster"
        log_info "Checking cluster status..."
        kubectl cluster-info
        return 1
    fi
    
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

configure_k3s() {
    print_section "Configuring k3s"
    
    if [ -z "$ISSUER_URL_ID" ]; then
        log_error "OIDC Issuer URL not available"
        return 1
    fi
    
    # Backup existing config if it exists
    if [ -f /etc/rancher/k3s/config.yaml ]; then
        sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.bak
        log_info "Backed up existing k3s configuration"
    fi
    
    # Update k3s configuration
    log_info "Updating k3s configuration..."
    {
        echo "kube-apiserver-arg:"
        echo " - service-account-issuer=$ISSUER_URL_ID"
        echo " - service-account-max-token-expiration=24h"
    } | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
    
    # Restart k3s
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
# Azure Resource Creation
################################################################################

create_azure_resources() {
    print_section "Creating Azure Resources"
    
    # Create Key Vault
    log_info "Creating Key Vault $AKV_NAME..."
    local kvResult
    kvResult=$(az keyvault create \
        --enable-rbac-authorization \
        --name "$AKV_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        2>&1)
    
    if [ $? -ne 0 ]; then
        log_error "Failed to create Key Vault. Error details:"
        log_error "$kvResult"
        return 1
    fi
    
    AKV_ID=$(echo "$kvResult" | jq -r '.id')
    if [ -z "$AKV_ID" ] || [ "$AKV_ID" == "null" ]; then
        log_error "Failed to get Key Vault ID"
        return 1
    fi
    
    # Get current user's Object ID
    local current_user_id
    current_user_id=$(az ad signed-in-user show --query id -o tsv)
    if [ -n "$current_user_id" ]; then
        log_info "Assigning Key Vault Administrator role..."
        az role assignment create \
            --assignee "$current_user_id" \
            --role "Key Vault Administrator" \
            --scope "$AKV_ID" \
            --only-show-errors || log_warning "Failed to assign Key Vault Administrator role"
    fi
    
    # Create Storage Account
    log_info "Creating Storage Account $STORAGE_NAME..."
    if ! az storage account create \
        --name "$STORAGE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --enable-hierarchical-namespace \
        --only-show-errors; then
        log_error "Failed to create storage account"
        return 1
    fi
    
    log_success "Azure resources created successfully"
    return 0
}

################################################################################
# Summary Functions
################################################################################

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
# Main Execution
################################################################################

main() {
    log_info "Starting Azure setup script..."
    
    # Check if running as root
    if is_root; then
        log_error "Please run this script as a normal user (not root)"
        log_info "The script will ask for sudo password when needed"
        exit 1
    fi
    
    # Get sudo privileges early but don't use them yet
    check_sudo_privileges || exit 1
    
    # Azure authentication (as normal user)
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
    
    # Execute operations with appropriate privileges
    log_info "Step 1/4: Registering Azure providers"
    register_providers || exit 1
    
    log_info "Step 2/4: Setting up connected Kubernetes"
    setup_connectedk8s || exit 1
    
    log_info "Step 3/4: Configuring k3s"
    configure_k3s || exit 1
    
    log_info "Step 4/4: Creating Azure resources"
    create_azure_resources || exit 1
    
    # Print summary
    print_summary
    
    log_success "Setup completed successfully!"
    log_info "To load the configuration in a new session, run: source azure_config.env"
}

################################################################################
# Script Entry Point
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