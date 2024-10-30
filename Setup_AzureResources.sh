#!/bin/bash

################################################################################
# Azure Arc Resource Setup Script
#
# This script automates the setup of Azure Arc-enabled Kubernetes cluster and
# associated resources, handling proper privilege management for each operation.
# Assumes K3s is already installed and configured.
#
# Features:
# - Automated Azure Arc enablement for K3s clusters
# - Smart resource naming with conflict resolution
# - Flexible options for existing resources
# - Comprehensive error handling and logging
#
# Requirements:
# - Run as a normal user (not root)
# - Sudo privileges available for system operations
# - K3s already installed and running
# - Azure CLI installed
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
    log_success "Successfully connected to Kubernetes cluster"
    
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
    if ! az login --use-device-code; then
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
################################################################################
# Azure Arc Setup Functions
################################################################################

# Function to setup connected kubernetes
setup_connectedk8s() {
    print_section "Setting up Connected Kubernetes"
    
    # Verify kubernetes prerequisites
    if ! verify_kubernetes_prereqs; then
        log_error "Failed to verify Kubernetes prerequisites"
        return 1
    fi
    
    # Add/update Arc extension
    if ! az extension show --name connectedk8s &>/dev/null; then
        log_info "Installing Azure Arc extension..."
        if ! az extension add --name connectedk8s --version 1.9.3 --yes; then
            log_error "Failed to install Azure Arc extension"
            return 1
        fi
    else
        log_info "Updating Azure Arc extension..."
        if ! az extension update --name connectedk8s; then
            log_error "Failed to update Azure Arc extension"
            return 1
        fi
    fi
    log_success "Azure Arc extension is ready"
    
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
    
    log_success "K3s OIDC configuration completed"
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
        else
            log_info "$provider already registered"
        fi
    done
    
    log_success "All providers successfully registered"
    return 0
}
################################################################################
# Resource Creation Functions
################################################################################

# Function to handle resource naming conflicts
handle_resource_conflict() {
    local resource_type="$1"
    local current_name="$2"
    local resource_group="$3"
    local existing_resource_group=""

    print_section "Handling $resource_type name conflict"
    
    if [ "$resource_type" = "akv" ]; then
        existing_resource_group=$(az keyvault show --name "$current_name" --query resourceGroup -o tsv 2>/dev/null)
    else
        existing_resource_group=$(az storage account show --name "$current_name" --query resourceGroup -o tsv 2>/dev/null)
    fi

    if [ "$existing_resource_group" = "$resource_group" ]; then
        log_info "A $resource_type with name '$current_name' exists in the same resource group."
        read -p "Do you want to use the existing $resource_type? (Y/n): " use_existing
        if [[ -z "$use_existing" || "${use_existing,,}" == "y"* ]]; then
            echo "USE_EXISTING"
            return 0
        fi
    else
        log_info "A $resource_type with name '$current_name' exists in a different resource group."
    fi

    while true; do
        echo -e "\nChoose an option:"
        echo "1) Enter a new name"
        echo "2) Let the script generate a name with random suffix"
        read -p "Enter your choice (1 or 2): " choice

        case $choice in
            1)
                if [ "$resource_type" = "akv" ]; then
                    while true; do
                        read -p "Enter new key vault base name: " kv_base
                        new_name=$(format_text "${kv_base}akv")
                        if [[ $new_name =~ ^[a-z0-9-]{3,24}$ ]]; then
                            break
                        else
                            log_error "Invalid key vault name. Use 3-24 lowercase letters, numbers, and hyphens."
                        fi
                    done
                else
                    while true; do
                        read -p "Enter new storage account base name: " storage_base
                        new_name=$(format_text "${storage_base}st")
                        if [[ $new_name =~ ^[a-z0-9]{3,24}$ ]]; then
                            break
                        else
                            log_error "Invalid storage account name. Use 3-24 lowercase letters and numbers."
                        fi
                    done
                fi
                echo "$new_name"
                return 0
                ;;
            2)
                echo "GENERATE_RANDOM"
                return 0
                ;;
            *)
                log_error "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

# Function to generate random name
generate_random_name() {
    local base_name="$1"
    local max_attempts="$2"
    local attempt=1
    local current_name="$base_name"

    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
            current_name="${base_name}$(printf '%04d' $((RANDOM % 10000)))"
        fi
        echo "$current_name"
        ((attempt++))
    done
    return 1
}

# Function to create Azure resources
create_azure_resources() {
    print_section "Creating Azure Resources"
    local max_attempts=5
    
    # Handle Key Vault creation
    local success=false
    local original_akv_name="$AKV_NAME"
    
    while [ "$success" = false ]; do
        log_info "Attempting to create Key Vault $AKV_NAME..."
        local kvResult
        kvResult=$(az keyvault create \
            --enable-rbac-authorization \
            --name "$AKV_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --output json 2>&1)
        
        if [ $? -eq 0 ]; then
            success=true
            # Extract ID from the correct JSON path
            AKV_ID=$(echo "$kvResult" | jq -r '.id // empty')
            if [ -z "$AKV_ID" ]; then
                # If .id is empty, try the full resource ID path
                AKV_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$AKV_NAME"
                if ! az keyvault show --name "$AKV_NAME" --query id -o tsv &>/dev/null; then
                    log_error "Failed to get Key Vault ID and couldn't verify vault existence"
                    return 1
                fi
            fi
            log_success "Key Vault $AKV_NAME created successfully with ID: $AKV_ID"
        else
            if echo "$kvResult" | grep -q "already exists"; then
                local action=$(handle_resource_conflict "akv" "$AKV_NAME" "$RESOURCE_GROUP")
                case $action in
                    "USE_EXISTING")
                        AKV_ID=$(az keyvault show --name "$AKV_NAME" --query id -o tsv)
                        log_success "Using existing Key Vault $AKV_NAME"
                        success=true
                        ;;
                    "GENERATE_RANDOM")
                        for new_name in $(generate_random_name "$original_akv_name" $max_attempts); do
                            AKV_NAME="$new_name"
                            log_info "Trying with generated name: $AKV_NAME"
                            continue 2
                        done
                        log_error "Failed to find available Key Vault name after $max_attempts attempts"
                        return 1
                        ;;
                    *)
                        AKV_NAME="$action"
                        ;;
                esac
            else
                log_error "Failed to create Key Vault: $kvResult"
                return 1
            fi
        fi
    done

    # Handle Storage Account creation
    success=false
    local original_storage_name="$STORAGE_NAME"
    
    while [ "$success" = false ]; do
        log_info "Creating Storage Account $STORAGE_NAME..."
        local stResult
        stResult=$(az storage account create \
            --name "$STORAGE_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --enable-hierarchical-namespace 2>&1)
        
        if [ $? -eq 0 ]; then
            success=true
            log_success "Storage Account $STORAGE_NAME created successfully"
        else
            if echo "$stResult" | grep -q "already exists"; then
                local action=$(handle_resource_conflict "storage" "$STORAGE_NAME" "$RESOURCE_GROUP")
                case $action in
                    "USE_EXISTING")
                        log_success "Using existing Storage Account $STORAGE_NAME"
                        success=true
                        ;;
                    "GENERATE_RANDOM")
                        for new_name in $(generate_random_name "$original_storage_name" $max_attempts); do
                            STORAGE_NAME="$new_name"
                            log_info "Trying with generated name: $STORAGE_NAME"
                            continue 2
                        done
                        log_error "Failed to find available Storage Account name after $max_attempts attempts"
                        return 1
                        ;;
                    *)
                        STORAGE_NAME="$action"
                        ;;
                esac
            else
                log_error "Failed to create Storage Account: $stResult"
                return 1
            fi
        fi
    done

    log_success "Azure resources created successfully"
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
        printf "%-40s: %d seconds\n" "$action" "${ACTION_TIMES[$action]}"
    done
    echo -e "\nTotal Execution Time: $total_time seconds"
    
    # Save configuration
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
    time_action "Get Resource Names" get_resource_names || exit 1
    
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
    time_action "Register Providers" register_providers || exit 1
    time_action "Setup Connected K8s" setup_connectedk8s || exit 1
    time_action "Configure K3s OIDC" configure_k3s_oidc || exit 1
    time_action "Create Azure Resources" create_azure_resources || exit 1
    
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