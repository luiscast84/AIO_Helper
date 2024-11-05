#!/bin/bash

################################################################################
# Azure Arc Resource Setup Script
#
# This script automates the setup of Azure Arc-enabled Kubernetes cluster and
# retrieves existing Azure resource information. It generates an automatic name
# for the Arc cluster and stores all resource information for future use.
#
# Features:
# - Automated Azure Arc enablement for K3s clusters
# - Automatic Arc cluster name generation
# - Retrieval and creation of Key Vault and Storage Account
# - Comprehensive error handling and logging
# - Configuration export for subsequent scripts
#
# Requirements:
# - Run as a normal user (not root)
# - Sudo privileges available for system operations
# - K3s already installed and running
# - Azure CLI installed with required extensions
# - kubectl and jq commands available
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

# Resource IDs and names (will be populated)
AKV_ID=""
AKV_NAME=""
ST_ID=""
ST_NAME=""
CLUSTER_NAME=""
ISSUER_URL_ID=""
OBJECT_ID=""
LOCATION=""
SUBSCRIPTION_ID=""

# Arrays to track status
declare -A ACTION_TIMES
declare -A INSTALLED_PACKAGES
declare -A SKIPPED_PACKAGES
declare -A FAILED_PACKAGES
declare -A SYSTEM_CHANGES

# Logging configuration
LOGFILE="/tmp/azure_setup_$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$LOGFILE")
exec 2> >(tee -a "$LOGFILE")

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

# Function to check if running as root
is_root() {
    [ "$(id -u)" -eq 0 ]
}

# Function to generate Arc cluster name
generate_arc_name() {
    local base="lab460"
    local random_num=$(printf "%04d" $((RANDOM % 10000)))
    echo "${base}${random_num}arc"
}
################################################################################
# Privilege Management Functions
################################################################################

# Function to check and store sudo credentials
check_sudo_privileges() {
    print_section "Checking Sudo Privileges"
    
    # Prevent running as root
    if is_root; then
        log_error "Please run this script as a normal user (not root)"
        log_info "The script will ask for sudo password when needed"
        exit 1
    fi
    
    # Inform user about sudo requirements
    log_info "This script requires sudo privileges for:"
    echo "  - Configuring k3s"
    echo "  - Modifying system settings"
    echo -e "\nOther operations like Azure login will run as current user"
    
    # Check if we can get sudo
    if ! sudo -v; then
        log_error "Unable to get sudo privileges"
        exit 1
    fi
    
    # Keep sudo alive in the background
    (while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null) &
    SUDO_KEEPER_PID=$!
    
    # Ensure we kill the sudo keeper on script exit
    trap 'kill $SUDO_KEEPER_PID 2>/dev/null' EXIT
    
    log_success "Sudo privileges confirmed"
}

################################################################################
# Kubernetes Verification Functions
################################################################################

# Function to verify kubernetes prerequisites with enhanced error handling
verify_kubernetes_prereqs() {
    print_section "Verifying Kubernetes Prerequisites"
    
    # Check if k3s is installed and running
    if ! systemctl is-active --quiet k3s; then
        log_error "K3s is not running"
        log_info "Attempting to start K3s service..."
        if sudo systemctl start k3s; then
            log_success "K3s service started successfully"
        else
            log_error "Failed to start K3s service"
            return 1
        fi
    fi
    log_success "K3s service is running"
    
    # Verify kubectl installation
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl is not installed"
        log_info "Please install kubectl first"
        return 1
    fi
    log_success "kubectl is installed"
    
    # Verify and set up kubeconfig with better error handling
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
        log_error "K3s configuration file not found"
        log_info "Waiting for K3s to generate configuration..."
        local max_wait=30
        local count=0
        while [ ! -f /etc/rancher/k3s/k3s.yaml ] && [ $count -lt $max_wait ]; do
            sleep 2
            ((count++))
        done
        if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
            log_error "K3s failed to generate configuration file"
            return 1
        fi
    fi
    
    # Set up kubeconfig if not already done
    if [ ! -f "$HOME/.kube/config" ]; then
        log_info "Setting up kubectl configuration..."
        mkdir -p "$HOME/.kube"
        if ! sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; then
            log_error "Failed to copy K3s configuration"
            return 1
        fi
        if ! sudo chown $(id -u):$(id -g) "$HOME/.kube/config"; then
            log_error "Failed to set permissions on kubectl configuration"
            return 1
        fi
        chmod 600 "$HOME/.kube/config"
    fi
    export KUBECONFIG="$HOME/.kube/config"
    
    # Verify cluster access with timeout
    log_info "Verifying cluster access..."
    local timeout=30
    local endtime=$(($(date +%s) + timeout))
    while ! kubectl cluster-info &>/dev/null && [ $(date +%s) -lt $endtime ]; do
        log_info "Waiting for cluster to become accessible..."
        sleep 2
    done
    
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Unable to connect to Kubernetes cluster after ${timeout}s"
        return 1
    fi
    
    # Get and validate cluster details
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    if [ "$node_count" -eq 0 ]; then
        log_error "No nodes found in the cluster"
        return 1
    fi
    
    local k8s_version
    k8s_version=$(kubectl version --output=json | jq -r '.serverVersion.gitVersion' 2>/dev/null)
    if [ -z "$k8s_version" ]; then
        log_warning "Unable to determine Kubernetes version"
    fi
    
    log_success "Successfully connected to Kubernetes cluster"
    log_info "Cluster details:"
    echo "  Nodes: $node_count"
    if [ -n "$k8s_version" ]; then
        echo "  Kubernetes version: $k8s_version"
    fi
    
    return 0
}
################################################################################
# Azure Authentication Functions
################################################################################

# Function to check Azure login status
check_azure_login() {
    print_section "Checking Azure Authentication"
    
    # Check if az CLI is installed
    if ! command -v az >/dev/null 2>&1; then
        log_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Try to get current Azure login status
    if az account show &>/dev/null; then
        log_info "Current Azure login information:"
        az account show --query "{Subscription:name,UserName:user.name,TenantID:tenantId}" -o table
        
        read -p "Continue with this Azure account? (Y/n): " use_current
        if [[ -z "$use_current" || "${use_current,,}" == "y"* ]]; then
            log_success "Using current Azure login"
            return 0
        fi
    fi
    
    # Need to login
    log_info "Azure login required. Opening browser..."
    if ! az login; then
        log_error "Azure login failed"
        return 1
    fi
    
    # Show login information
    log_info "Logged in successfully. Account information:"
    az account show --query "{Subscription:name,UserName:user.name,TenantID:tenantId}" -o table
    return 0
}

################################################################################
# Resource Management Functions
################################################################################

# Function to create Key Vault
create_key_vault() {
    local resource_group="$1"
    local location="$2"
    print_section "Creating Azure Key Vault"
    
    # Generate unique name for Key Vault
    local base_name="lab460kv"
    local random_num=$(printf "%04d" $((RANDOM % 10000)))
    local kv_name="${base_name}${random_num}"
    
    log_info "Creating Key Vault: $kv_name"
    log_info "Location: $location"
    log_info "Resource Group: $resource_group"
    
    if az keyvault create \
        --name "$kv_name" \
        --resource-group "$resource_group" \
        --location "$location" \
        --sku "standard"; then
        
        AKV_NAME="$kv_name"
        AKV_ID=$(az keyvault show \
            --name "$kv_name" \
            --resource-group "$resource_group" \
            --query "id" \
            --output tsv)
            
        log_success "Key Vault created successfully"
        log_info "Key Vault ID: $AKV_ID"
        return 0
    else
        log_error "Failed to create Key Vault"
        return 1
    fi
}

# Function to create Storage Account
create_storage_account() {
    local resource_group="$1"
    local location="$2"
    print_section "Creating Azure Storage Account"
    
    # Generate unique name for Storage Account (must be lowercase, no special chars)
    local base_name="lab460st"
    local random_num=$(printf "%04d" $((RANDOM % 10000)))
    local st_name="${base_name}${random_num}"
    
    log_info "Creating Storage Account: $st_name"
    log_info "Location: $location"
    log_info "Resource Group: $resource_group"
    
    if az storage account create \
        --name "$st_name" \
        --resource-group "$resource_group" \
        --location "$location" \
        --enable-hierarchical-namespace \
        --sku "Standard_LRS" \
        --kind "StorageV2" \
        --https-only true \
        --min-tls-version "TLS1_2"; then
        
        ST_NAME="$st_name"
        ST_ID=$(az storage account show \
            --name "$st_name" \
            --resource-group "$resource_group" \
            --query "id" \
            --output tsv)
            
        log_success "Storage Account created successfully"
        log_info "Storage Account ID: $ST_ID"
        return 0
    else
        log_error "Failed to create Storage Account"
        return 1
    fi
}

# Function to get existing resource IDs with creation fallback
get_existing_resource_ids() {
    local resource_group="$1"
    print_section "Getting Existing Resource IDs"
    
    # Get Key Vault information
    log_info "Looking for existing Key Vault..."
    local kv_list
    kv_list=$(az keyvault list -g "$resource_group" --query "[].{name:name, id:id}" -o json)
    
    if [ -n "$kv_list" ] && [ "$kv_list" != "[]" ]; then
        # Get the first Key Vault if multiple exist
        AKV_NAME=$(echo "$kv_list" | jq -r '.[0].name')
        AKV_ID=$(echo "$kv_list" | jq -r '.[0].id')
        log_success "Found Key Vault: $AKV_NAME"
        log_info "Key Vault ID: $AKV_ID"
    else
        log_warning "No Key Vault found in resource group $resource_group"
        log_info "Creating new Key Vault..."
        create_key_vault "$resource_group" "$LOCATION" || return 1
    fi
    
    # Get Storage Account information
    log_info "Looking for existing Storage Account..."
    local st_list
    st_list=$(az storage account list -g "$resource_group" --query "[].{name:name, id:id}" -o json)
    
    if [ -n "$st_list" ] && [ "$st_list" != "[]" ]; then
        # Get the first Storage Account if multiple exist
        ST_NAME=$(echo "$st_list" | jq -r '.[0].name')
        ST_ID=$(echo "$st_list" | jq -r '.[0].id')
        log_success "Found Storage Account: $ST_NAME"
        log_info "Storage Account ID: $ST_ID"
    else
        log_warning "No Storage Account found in resource group $resource_group"
        log_info "Creating new Storage Account..."
        create_storage_account "$resource_group" "$LOCATION" || return 1
    fi
    
    return 0
}

# Function to get and validate subscription
get_subscription() {
    print_section "Checking Subscription"
    
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

# Function to check resource group existence and location
check_resource_group() {
    print_section "Checking Resource Group"
    
    log_info "Checking for resource group $RESOURCE_GROUP..."
    
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
        log_success "Found existing resource group $RESOURCE_GROUP in location: $LOCATION"
        
        # Get additional resource group details for logging
        local tags=$(az group show --name "$RESOURCE_GROUP" --query tags -o json)
        local resource_count=$(az resource list --resource-group "$RESOURCE_GROUP" --query "length(@)")
        
        log_info "Resource group details:"
        echo "  Location: $LOCATION"
        echo "  Resource count: $resource_count"
        if [ "$tags" != "{}" ] && [ "$tags" != "null" ]; then
            echo "  Tags: $tags"
        fi
        return 0
    else
        log_warning "Resource group $RESOURCE_GROUP not found"
        get_location
        log_info "Creating resource group $RESOURCE_GROUP in $LOCATION..."
        if ! az group create --name "$RESOURCE_GROUP" --location "$LOCATION"; then
            log_error "Failed to create resource group"
            return 1
        fi
        log_success "Resource group created successfully"
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
            log_success "Selected location: $LOCATION"
            break
        else
            log_error "Invalid location. Please try again."
        fi
    done
}
################################################################################
# Azure Arc Setup Functions
################################################################################

# Function to setup connected kubernetes with enhanced error handling
setup_connectedk8s() {
    print_section "Setting up Connected Kubernetes"
    
    # Generate Arc cluster name if not already set
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME=$(generate_arc_name)
        log_info "Generated Arc cluster name: $CLUSTER_NAME"
    else
        log_info "Using existing Arc cluster name: $CLUSTER_NAME"
    fi
    
    # Check if cluster already exists
    if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
        log_warning "Cluster $CLUSTER_NAME already exists in resource group $RESOURCE_GROUP"
        
        # Ask user what to do
        read -p "Do you want to delete and recreate the cluster? (y/N): " recreate_cluster
        if [[ "${recreate_cluster,,}" == "y"* ]]; then
            log_info "Deleting existing cluster..."
            az connectedk8s delete --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --yes
            # Wait for deletion
            local timeout=300
            local endtime=$(($(date +%s) + timeout))
            while az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; do
                if [ $(date +%s) -gt $endtime ]; then
                    log_error "Timeout waiting for cluster deletion"
                    return 1
                fi
                log_info "Waiting for cluster deletion..."
                sleep 10
            done
        else
            log_info "Using existing cluster"
            # Get existing OIDC Issuer URL
            ISSUER_URL_ID=$(az connectedk8s show \
                --resource-group "$RESOURCE_GROUP" \
                --name "$CLUSTER_NAME" \
                --query oidcIssuerProfile.issuerUrl \
                --output tsv)
            return 0
        fi
    fi
    
    # Configure extension settings to avoid prompts
    log_info "Configuring Azure CLI extension settings..."
    az config set extension.use_dynamic_install=yes_without_prompt &>/dev/null
    az config set extension.dynamic_install.allow_preview=true &>/dev/null
    
    # Verify required extensions
    local required_extensions=("connectedk8s" "k8s-extension" "customlocation")
    for ext in "${required_extensions[@]}"; do
        if ! az extension show --name "$ext" &>/dev/null; then
            log_info "Installing Azure CLI extension: $ext"
            if ! az extension add --name "$ext" --yes; then
                log_error "Failed to install $ext extension"
                return 1
            fi
        fi
    done
    
    # Connect cluster with retry logic
    log_info "Connecting cluster to Azure Arc..."
    log_info "Using configuration:"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Location: $LOCATION"
    
    local max_attempts=3
    local attempt=1
    local success=false
    
    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log_info "Attempt $attempt of $max_attempts to connect cluster..."
        
        if az connectedk8s connect \
            --name "$CLUSTER_NAME" \
            -l "$LOCATION" \
            --resource-group "$RESOURCE_GROUP" \
            --subscription "$SUBSCRIPTION_ID" \
            --enable-oidc-issuer \
            --enable-workload-identity \
            --yes; then
            success=true
            break
        else
            log_warning "Attempt $attempt failed"
            if [ $attempt -lt $max_attempts ]; then
                log_info "Waiting before retry..."
                sleep 30
            fi
        fi
        ((attempt++))
    done
    
    if [ "$success" = false ]; then
        log_error "Failed to connect Kubernetes cluster after $max_attempts attempts"
        return 1
    fi
    
    # Get OIDC Issuer URL with retry
    log_info "Retrieving OIDC Issuer URL..."
    local retry_count=0
    local max_retries=10
    
    while [ $retry_count -lt $max_retries ]; do
        ISSUER_URL_ID=$(az connectedk8s show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$CLUSTER_NAME" \
            --query oidcIssuerProfile.issuerUrl \
            --output tsv)
            
        if [ -n "$ISSUER_URL_ID" ]; then
            break
        fi
        
        ((retry_count++))
        log_info "Waiting for OIDC Issuer URL (attempt $retry_count of $max_retries)..."
        sleep 15
    done
    
    if [ -z "$ISSUER_URL_ID" ]; then
        log_error "Failed to get OIDC Issuer URL"
        return 1
    fi
    
    # Enable additional features with error handling
    log_info "Enabling Arc features..."
    if ! OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv); then
        log_error "Failed to get Object ID for Arc features"
        return 1
    fi
    
    if ! az connectedk8s enable-features \
        -n "$CLUSTER_NAME" \
        -g "$RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --custom-locations-oid "$OBJECT_ID" \
        --features cluster-connect custom-locations; then
        log_warning "Failed to enable some Arc features - cluster will still work but with limited functionality"
    fi
    
    log_success "Successfully connected to Azure Arc"
    log_info "OIDC Issuer URL: $ISSUER_URL_ID"
    return 0
}

# Function to configure k3s OIDC
configure_k3s_oidc() {
    print_section "Configuring K3s OIDC"
    
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
    log_info "Updating k3s configuration for OIDC..."
    log_info "Setting service account issuer to: $ISSUER_URL_ID"
    {
        echo "kube-apiserver-arg:"
        echo "  - service-account-issuer=$ISSUER_URL_ID"
        echo "  - service-account-max-token-expiration=24h"
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
    
    # Verify OIDC configuration
    log_info "Verifying OIDC configuration..."
    local node_status=$(kubectl get nodes -o wide)
    log_success "K3s OIDC configuration completed"
    log_info "Current node status:"
    echo "$node_status"
    return 0
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
    
    log_info "Starting provider registration check for ${#providers[@]} providers"
    
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
            
            if [ "$status" != "Registered" ]; then
                log_error "Provider $provider failed to register in time"
                return 1
            fi
            log_success "Provider $provider registered successfully"
        else
            log_success "$provider already registered"
        fi
    done
    
    log_success "All providers successfully registered"
    return 0
}
################################################################################
# Configuration Management Functions
################################################################################

# Function to backup configuration
backup_config() {
    local backup_dir="$HOME/.azure_setup_backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/azure_config_$timestamp.env"
    
    mkdir -p "$backup_dir"
    if [ -f azure_config.env ]; then
        cp azure_config.env "$backup_file"
        log_info "Configuration backed up to: $backup_file"
    fi
}

# Function to save configuration with error handling
save_configuration() {
    print_section "Saving Configuration"
    
    # Backup existing configuration
    backup_config
    
    # Create new configuration file with error checking
    if ! cat > azure_config.env << EOF
# Azure Arc Configuration - Generated on $(date)
# Script Version: 3.0
# Generated by: $USER

# Azure Resource Configuration
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export LOCATION="$LOCATION"
export RESOURCE_GROUP="$RESOURCE_GROUP"

# Arc Cluster Configuration
export CLUSTER_NAME="$CLUSTER_NAME"
export ISSUER_URL_ID="$ISSUER_URL_ID"
export OBJECT_ID="$OBJECT_ID"

# Azure Resources
export AKV_NAME="$AKV_NAME"
export AKV_ID="$AKV_ID"
export ST_NAME="$ST_NAME"
export ST_ID="$ST_ID"

# Script Execution Information
export SCRIPT_EXECUTION_TIME="$(($(date +%s) - SCRIPT_START_TIME))"
export SCRIPT_EXECUTION_DATE="$(date)"
export SCRIPT_LOG_FILE="$LOGFILE"
EOF
    then
        log_error "Failed to save configuration file"
        return 1
    fi
    
    # Verify file was created and is readable
    if [ ! -f azure_config.env ] || [ ! -r azure_config.env ]; then
        log_error "Configuration file was not created properly"
        return 1
    fi
    
    log_success "Configuration saved to azure_config.env"
    return 0
}

# Function to print detailed status
print_detailed_status() {
    print_section "Detailed Status Report"
    
    echo -e "\n${GREEN}Azure Resource Status:${NC}"
    echo "Resource Group: $RESOURCE_GROUP (Location: $LOCATION)"
    echo "Subscription: $SUBSCRIPTION_ID"
    
    echo -e "\n${GREEN}Key Vault Status:${NC}"
    if [ -n "$AKV_NAME" ]; then
        echo "Name: $AKV_NAME"
        echo "ID: $AKV_ID"
        if az keyvault show --name "$AKV_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
            echo "Status: Available"
        else
            echo "Status: Not Available"
        fi
    else
        echo "Status: Not Configured"
    fi
    
    echo -e "\n${GREEN}Storage Account Status:${NC}"
    if [ -n "$ST_NAME" ]; then
        echo "Name: $ST_NAME"
        echo "ID: $ST_ID"
        if az storage account show --name "$ST_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
            echo "Status: Available"
        else
            echo "Status: Not Available"
        fi
    else
        echo "Status: Not Configured"
    fi
    
    echo -e "\n${GREEN}Arc Cluster Status:${NC}"
    if [ -n "$CLUSTER_NAME" ]; then
        echo "Name: $CLUSTER_NAME"
        echo "OIDC Issuer URL: $ISSUER_URL_ID"
        if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
            echo "Status: Connected"
        else
            echo "Status: Not Connected"
        fi
    else
        echo "Status: Not Configured"
    fi
}

# Function to print summary
print_summary() {
    local end_time=$(date +%s)
    local total_time=$((end_time - SCRIPT_START_TIME))
    
    print_section "Execution Summary"
    
    echo -e "\n${GREEN}Resource Configuration:${NC}"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    
    echo -e "\n${GREEN}Arc Configuration:${NC}"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "OIDC Issuer URL: $ISSUER_URL_ID"
    echo "Object ID: $OBJECT_ID"
    
    echo -e "\n${GREEN}Existing Resources:${NC}"
    echo "Key Vault Name: $AKV_NAME"
    echo "Key Vault ID: $AKV_ID"
    echo "Storage Account Name: $ST_NAME"
    echo "Storage Account ID: $ST_ID"
    
    echo -e "\n${YELLOW}Execution Times:${NC}"
    for action in "${!ACTION_TIMES[@]}"; do
        printf "%-40s: %d seconds\n" "$action" "${ACTION_TIMES[$action]}"
    done
    echo -e "\nTotal Execution Time: $total_time seconds"
}

################################################################################
# Main Execution
################################################################################

# Main execution function with enhanced error handling
main() {
    local error_count=0
    log_info "Starting Azure Arc and resource setup..."
    
    # Initial checks
    if is_root; then
        log_error "Please run this script as a normal user (not root)"
        log_info "The script will ask for sudo password when needed"
        exit 1
    fi
    
    # Get sudo privileges early
    if ! check_sudo_privileges; then
        log_error "Failed to obtain sudo privileges"
        exit 1
    fi
    
    # Create a temporary directory for the script
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
    # Verify kubernetes prerequisites
    if ! time_action "Verify Kubernetes" verify_kubernetes_prereqs; then
        ((error_count++))
        log_warning "Kubernetes verification failed - continuing with reduced functionality"
    fi
    
    # Azure authentication and setup
    if ! time_action "Azure Login" check_azure_login || \
       ! time_action "Get Subscription" get_subscription || \
       ! time_action "Check Resource Group" check_resource_group; then
        log_error "Failed to setup Azure authentication"
        exit 1
    fi
    
    # Get or create resource IDs
    if ! time_action "Get Resource IDs" get_existing_resource_ids "$RESOURCE_GROUP"; then
        log_error "Failed to get or create required Azure resources"
        exit 1
    fi
    
    # Show configuration and ask for confirmation
    print_section "Configuration to be applied"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Key Vault: $AKV_NAME"
    echo "Storage Account: $ST_NAME"
    echo "Cluster Name: $CLUSTER_NAME (will be generated if not exists)"
    
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    
    # Execute operations with appropriate privileges
    if ! time_action "Register Providers" register_providers; then
        ((error_count++))
        log_warning "Some providers failed to register"
    fi
    
    if ! time_action "Setup Connected K8s" setup_connectedk8s; then
        ((error_count++))
        log_error "Failed to setup connected Kubernetes"
    fi
    
    if ! time_action "Configure K3s OIDC" configure_k3s_oidc; then
        ((error_count++))
        log_warning "Failed to configure K3s OIDC"
    fi
    
    # Validate final setup
    if ! time_action "Validate Resources" validate_azure_resources; then
        ((error_count++))
        log_warning "Some resources failed validation"
    fi
    
    # Save configuration
    if ! save_configuration; then
        ((error_count++))
        log_error "Failed to save configuration"
    fi
    
    # Print detailed status
    print_detailed_status
    
    # Print summary
    print_summary
    
    # Final status
    if [ $error_count -eq 0 ]; then
        log_success "Setup completed successfully!"
    else
        log_warning "Setup completed with $error_count warnings/errors"
        log_info "Please check the log file for details: $LOGFILE"
    fi
    
    log_info "To load the configuration in a new session, run: source azure_config.env"
    log_info "Configuration variables are now available for use in other scripts"
    
    return $error_count
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
REQUIRED_COMMANDS=(az jq kubectl)
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v $cmd &>/dev/null; then
        MISSING_COMMANDS+=($cmd)
    fi
done

if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    echo "Error: Required commands not found: ${MISSING_COMMANDS[*]}"
    echo "Please install missing commands and try again"
    exit 1
fi

# Execute main function and capture exit code
main
exit $?