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
# - Retrieval of existing Key Vault and Storage Account IDs
# - Comprehensive error handling and logging
# - Configuration export for subsequent scripts
#
# Requirements:
# - Run as a normal user (not root)
# - Sudo privileges available for system operations
# - K3s already installed and running
# - Azure CLI installed with required extensions
# - kubectl and jq commands available
# - Existing Key Vault and Storage Account in the resource group
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

# Function to verify kubernetes prerequisites
verify_kubernetes_prereqs() {
    print_section "Verifying Kubernetes Prerequisites"
    
    # Check if k3s is installed and running
    if ! systemctl is-active --quiet k3s; then
        log_error "K3s is not running. Please ensure K3s is installed and running"
        return 1
    fi
    log_success "K3s service is running"
    
    # Verify kubectl is installed
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl is not installed. Please install kubectl first"
        return 1
    fi
    log_success "kubectl is installed"
    
    # Verify kubeconfig
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
        log_error "K3s configuration file not found at /etc/rancher/k3s/k3s.yaml"
        return 1
    fi
    
    # Set up kubeconfig if not already done
    if [ ! -f "$HOME/.kube/config" ]; then
        mkdir -p "$HOME/.kube"
        sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
        sudo chown $(id -u):$(id -g) "$HOME/.kube/config"
        chmod 600 "$HOME/.kube/config"
    fi
    export KUBECONFIG="$HOME/.kube/config"
    
    # Verify cluster access
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Unable to connect to Kubernetes cluster"
        return 1
    fi
    
    # Get cluster details for logging
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local k8s_version=$(kubectl version --output=json | jq -r '.serverVersion.gitVersion')
    
    log_success "Successfully connected to Kubernetes cluster"
    log_info "Cluster details:"
    echo "  Nodes: $node_count"
    echo "  Kubernetes version: $k8s_version"
    
    return 0
}

# Function to get existing resource IDs
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
        log_error "No Key Vault found in resource group $resource_group"
        return 1
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
        log_error "No Storage Account found in resource group $resource_group"
        return 1
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
# Subscription Management Functions
################################################################################

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

################################################################################
# Resource Group Management Functions
################################################################################

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

# Function to setup connected kubernetes
setup_connectedk8s() {
    print_section "Setting up Connected Kubernetes"
    
    # Generate Arc cluster name
    CLUSTER_NAME=$(generate_arc_name)
    log_info "Generated Arc cluster name: $CLUSTER_NAME"
    
    # Configure extension settings to avoid prompts
    log_info "Configuring Azure CLI extension settings..."
    az config set extension.use_dynamic_install=yes_without_prompt &>/dev/null
    az config set extension.dynamic_install.allow_preview=true &>/dev/null
    
    # Connect cluster
    log_info "Connecting cluster to Azure Arc..."
    log_info "Using configuration:"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Location: $LOCATION"
    
    # Use yes flag to accept installation of extensions
    if ! az connectedk8s connect \
        --name "$CLUSTER_NAME" \
        -l "$LOCATION" \
        --resource-group "$RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --enable-oidc-issuer \
        --enable-workload-identity \
        --yes; then
        log_error "Failed to connect Kubernetes cluster"
        return 1
    fi
    
    # Get OIDC Issuer URL
    log_info "Retrieving OIDC Issuer URL..."
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
        echo " - service-account-issuer=$ISSUER_URL_ID"
        echo " - service-account-max-token-expiration=24h"
    } | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
    
    # Enable features
    print_section "Enabling Arc Features"
    OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
    track_operation "Enable Arc Features" az connectedk8s enable-features \
        -n $CLUSTER_NAME \
        -g $RESOURCE_GROUP \
        --subscription $SUBSCRIPTION_ID \
        --custom-locations-oid $OBJECT_ID \
        --features cluster-connect custom-locations

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

################################################################################
# Azure Provider Registration Functions
################################################################################

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
# Summary and Configuration Functions
################################################################################

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
    
    # Save configuration for future use
    log_info "Saving configuration to azure_config.env..."
    cat > azure_config.env << EOF
# Azure Arc Configuration - Generated on $(date)
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export LOCATION="$LOCATION"
export RESOURCE_GROUP="$RESOURCE_GROUP"
export CLUSTER_NAME="$CLUSTER_NAME"
export ISSUER_URL_ID="$ISSUER_URL_ID"
export OBJECT_ID="$OBJECT_ID"

# Existing Resource IDs
export AKV_NAME="$AKV_NAME"
export AKV_ID="$AKV_ID"
export ST_NAME="$ST_NAME"
export ST_ID="$ST_ID"

# Script Execution Information
export SCRIPT_EXECUTION_TIME="$total_time"
export SCRIPT_EXECUTION_DATE="$(date)"
EOF
    log_success "Configuration saved to azure_config.env"
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "Starting Azure Arc and resource setup..."
    
    # Initial checks
    if is_root; then
        log_error "Please run this script as a normal user (not root)"
        log_info "The script will ask for sudo password when needed"
        exit 1
    fi
    
    # Get sudo privileges early
    check_sudo_privileges || exit 1
    
    # Verify kubernetes prerequisites
    time_action "Verify Kubernetes" verify_kubernetes_prereqs || exit 1
    
    # Azure authentication and setup
    time_action "Azure Login" check_azure_login || exit 1
    time_action "Get Subscription" get_subscription || exit 1
    time_action "Check Resource Group" check_resource_group || exit 1
    
    # Get existing resource IDs
    time_action "Get Resource IDs" get_existing_resource_ids "$RESOURCE_GROUP" || exit 1
    
    # Show configuration before proceeding
    print_section "Configuration to be applied"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Key Vault: $AKV_NAME"
    echo "Storage Account: $ST_NAME"
    echo "Cluster Name: $CLUSTER_NAME"
    
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    
    # Execute operations with appropriate privileges
    time_action "Register Providers" register_providers || exit 1
    time_action "Setup Connected K8s" setup_connectedk8s || exit 1
    time_action "Configure K3s OIDC" configure_k3s_oidc || exit 1
    
    # Print summary
    print_summary
    
    log_success "Setup completed successfully!"
    log_info "To load the configuration in a new session, run: source azure_config.env"
    log_info "Configuration variables are now available for use in other scripts"
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