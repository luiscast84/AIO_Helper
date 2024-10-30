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
# - Reuse existing Arc clusters and Azure resources
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

# Function to check if cluster is already Arc-enabled
check_existing_arc_cluster() {
    local resource_group="$1"
    local cluster_name="$2"
    
    log_info "Checking for existing Arc-enabled cluster..."
    
    # List all Arc clusters in the resource group
    local clusters
    clusters=$(az connectedk8s list -g "$resource_group" --query "[].name" -o tsv)
    
    if [ $? -eq 0 ] && [ -n "$clusters" ]; then
        log_info "Found existing Arc-enabled clusters in resource group $resource_group:"
        az connectedk8s list -g "$resource_group" --query "[].{Name:name, State:provisioningState}" -o table
        
        read -p "Would you like to use an existing cluster? (Y/n): " use_existing
        if [[ -z "$use_existing" || "${use_existing,,}" == "y"* ]]; then
            # If there's only one cluster, use it automatically
            if [ $(echo "$clusters" | wc -l) -eq 1 ]; then
                CLUSTER_NAME=$clusters
                log_info "Using existing cluster: $CLUSTER_NAME"
            else
                # Let user select from available clusters
                echo "Available clusters:"
                local i=1
                local cluster_array=()
                while IFS= read -r cluster; do
                    echo "$i) $cluster"
                    cluster_array+=("$cluster")
                    ((i++))
                done <<< "$clusters"
                
                while true; do
                    read -p "Enter cluster number (1-${#cluster_array[@]}): " selection
                    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#cluster_array[@]}" ]; then
                        CLUSTER_NAME="${cluster_array[$((selection-1))]}"
                        break
                    else
                        log_error "Invalid selection. Please try again."
                    fi
                done
            fi
            
            # Get OIDC Issuer URL for the selected cluster
            ISSUER_URL_ID=$(az connectedk8s show \
                --resource-group "$resource_group" \
                --name "$CLUSTER_NAME" \
                --query oidcIssuerProfile.issuerUrl \
                --output tsv)
            
            if [ -n "$ISSUER_URL_ID" ]; then
                log_success "Using existing Arc cluster: $CLUSTER_NAME"
                return 0
            fi
        fi
    fi
    return 1
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
    
    # Get cluster name if not already set
    if [ -z "$CLUSTER_NAME" ]; then
        while true; do
            read -p "Enter cluster name (lowercase, no spaces): " CLUSTER_NAME
            CLUSTER_NAME=$(format_text "$CLUSTER_NAME")
            if [[ $CLUSTER_NAME =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
                break
            else
                log_error "Invalid cluster name. Use lowercase letters, numbers, and hyphens."
            fi
        done
    fi
    
    # Get storage account name if not already set
    if [ -z "$STORAGE_NAME" ]; then
        while true; do
            read -p "Enter storage account base name: " storage_base
            STORAGE_NAME=$(format_text "${storage_base}st")
            if [[ $STORAGE_NAME =~ ^[a-z0-9]{3,24}$ ]]; then
                break
            else
                log_error "Invalid storage account name. Use 3-24 lowercase letters and numbers."
            fi
        done
    fi
    
    # Get key vault name if not already set
    if [ -z "$AKV_NAME" ]; then
        while true; do
            read -p "Enter key vault base name: " kv_base
            AKV_NAME=$(format_text "${kv_base}akv")
            if [[ $AKV_NAME =~ ^[a-z0-9-]{3,24}$ ]]; then
                break
            else
                log_error "Invalid key vault name. Use 3-24 lowercase letters, numbers, and hyphens."
            fi
        done
    fi
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

# Function to handle resource selection and naming
handle_resource_selection() {
    local resource_type="$1"    # 'akv' or 'storage'
    local current_name="$2"
    local resource_group="$3"
    local existing_resources=""
    local resource_exists=false

    print_section "Handling $resource_type setup"
    
    # Check for existing resources in the resource group
    if [ "$resource_type" = "akv" ]; then
        existing_resources=$(az keyvault list -g "$resource_group" --query "[].{Name:name, URI:properties.vaultUri}" -o table)
        if [ -n "$existing_resources" ]; then
            resource_exists=true
            log_info "Found existing Key Vaults in resource group $resource_group:"
            echo "$existing_resources"
        fi
    else
        existing_resources=$(az storage account list -g "$resource_group" --query "[].{Name:name, Location:location}" -o table)
        if [ -n "$existing_resources" ]; then
            resource_exists=true
            log_info "Found existing Storage Accounts in resource group $resource_group:"
            echo "$existing_resources"
        fi
    fi

    if [ "$resource_exists" = true ]; then
        echo -e "\nChoose an option:"
        echo "1) Use an existing resource from the resource group"
        echo "2) Create new with a custom name"
        echo "3) Create new with an auto-generated name"
        read -p "Enter your choice (1-3): " choice

        case $choice in
            1)
                # Handle existing resource selection
                if [ "$resource_type" = "akv" ]; then
                    local vaults=$(az keyvault list -g "$resource_group" --query "[].name" -o tsv)
                    select vault in $vaults; do
                        if [ -n "$vault" ]; then
                            AKV_NAME="$vault"
                            AKV_ID=$(az keyvault show -g "$resource_group" -n "$vault" --query "id" -o tsv)
                            log_success "Using existing Key Vault: $vault"
                            echo "USE_EXISTING"
                            return 0
                        else
                            log_error "Invalid selection. Please try again."
                        fi
                    done
                else
                    local accounts=$(az storage account list -g "$resource_group" --query "[].name" -o tsv)
                    select account in $accounts; do
                        if [ -n "$account" ]; then
                            STORAGE_NAME="$account"
                            log_success "Using existing Storage Account: $account"
                            echo "USE_EXISTING"
                            return 0
                        else
                            log_error "Invalid selection. Please try again."
                        fi
                    done
                fi
                ;;
            2)
                # Handle custom name
                if [ "$resource_type" = "akv" ]; then
                    while true; do
                        read -p "Enter new key vault base name: " kv_base
                        new_name=$(format_text "${kv_base}akv")
                        if [[ $new_name =~ ^[a-z0-9-]{3,24}$ ]]; then
                            echo "$new_name"
                            return 0
                        else
                            log_error "Invalid key vault name. Use 3-24 lowercase letters, numbers, and hyphens."
                        fi
                    done
                else
                    while true; do
                        read -p "Enter new storage account base name: " storage_base
                        new_name=$(format_text "${storage_base}st")
                        if [[ $new_name =~ ^[a-z0-9]{3,24}$ ]]; then
                            echo "$new_name"
                            return 0
                        else
                            log_error "Invalid storage account name. Use 3-24 lowercase letters and numbers."
                        fi
                    done
                fi
                ;;
            3)
                echo "GENERATE_RANDOM"
                return 0
                ;;
            *)
                log_error "Invalid choice. Please enter 1, 2, or 3."
                return 1
                ;;
        esac
    else
        # No existing resources, proceed with normal conflict handling
        log_info "No existing $resource_type found in resource group $resource_group."
        echo -e "\nChoose an option:"
        echo "1) Create new with a custom name"
        echo "2) Create new with an auto-generated name"
        read -p "Enter your choice (1-2): " choice

        case $choice in
            1)
                # Handle custom name (same as above)
                if [ "$resource_type" = "akv" ]; then
                    while true; do
                        read -p "Enter new key vault base name: " kv_base
                        new_name=$(format_text "${kv_base}akv")
                        if [[ $new_name =~ ^[a-z0-9-]{3,24}$ ]]; then
                            echo "$new_name"
                            return 0
                        else
                            log_error "Invalid key vault name. Use 3-24 lowercase letters, numbers, and hyphens."
                        fi
                    done
                else
                    while true; do
                        read -p "Enter new storage account base name: " storage_base
                        new_name=$(format_text "${storage_base}st")
                        if [[ $new_name =~ ^[a-z0-9]{3,24}$ ]]; then
                            echo "$new_name"
                            return 0
                        else
                            log_error "Invalid storage account name. Use 3-24 lowercase letters and numbers."
                        fi
                    done
                fi
                ;;
            2)
                echo "GENERATE_RANDOM"
                return 0
                ;;
            *)
                log_error "Invalid choice. Please enter 1 or 2."
                return 1
                ;;
        esac
    fi
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
################################################################################
# Resource Creation Implementation
################################################################################

# Function to create Azure resources
create_azure_resources() {
    print_section "Creating Azure Resources"
    local max_attempts=5
    
    # Handle Key Vault creation
    local success=false
    local original_akv_name="$AKV_NAME"
    
    while [ "$success" = false ]; do
        local action
        
        if [ -z "$AKV_ID" ]; then  # Only if not already selected an existing vault
            action=$(handle_resource_selection "akv" "$AKV_NAME" "$RESOURCE_GROUP")
            
            case $action in
                "USE_EXISTING")
                    success=true
                    continue
                    ;;
                "GENERATE_RANDOM")
                    for new_name in $(generate_random_name "$original_akv_name" $max_attempts); do
                        AKV_NAME="$new_name"
                        log_info "Trying with generated name: $AKV_NAME"
                        kvResult=$(az keyvault create \
                            --enable-rbac-authorization \
                            --name "$AKV_NAME" \
                            --resource-group "$RESOURCE_GROUP" 2>&1)
                        if [ $? -eq 0 ]; then
                            success=true
                            AKV_ID=$(echo "$kvResult" | jq -r '.id // empty')
                            if [ -z "$AKV_ID" ]; then
                                AKV_ID=$(az keyvault show --name "$AKV_NAME" --query id -o tsv)
                            fi
                            break
                        fi
                    done
                    if [ "$success" = false ]; then
                        log_error "Failed to find available Key Vault name after $max_attempts attempts"
                        return 1
                    fi
                    ;;
                *)
                    AKV_NAME="$action"
                    ;;
            esac
        else
            success=true
            continue
        fi

        if [ "$success" = false ]; then
            log_info "Attempting to create Key Vault $AKV_NAME..."
            local kvResult
            kvResult=$(az keyvault create \
                --enable-rbac-authorization \
                --name "$AKV_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --output json 2>&1)
            
            if [ $? -eq 0 ]; then
                success=true
                AKV_ID=$(echo "$kvResult" | jq -r '.id // empty')
                if [ -z "$AKV_ID" ]; then
                    AKV_ID=$(az keyvault show --name "$AKV_NAME" --query id -o tsv)
                fi
                log_success "Key Vault $AKV_NAME created successfully"
            elif ! echo "$kvResult" | grep -q "already exists"; then
                log_error "Failed to create Key Vault: $kvResult"
                return 1
            fi
        fi
    done

    # Handle Storage Account creation
    success=false
    local original_storage_name="$STORAGE_NAME"
    
    while [ "$success" = false ]; do
        local action
        
        if [ -z "$STORAGE_NAME" ] || ! az storage account show --name "$STORAGE_NAME" &>/dev/null; then
            action=$(handle_resource_selection "storage" "$STORAGE_NAME" "$RESOURCE_GROUP")
            
            case $action in
                "USE_EXISTING")
                    success=true
                    continue
                    ;;
                "GENERATE_RANDOM")
                    for new_name in $(generate_random_name "$original_storage_name" $max_attempts); do
                        STORAGE_NAME="$new_name"
                        log_info "Trying with generated name: $STORAGE_NAME"
                        if az storage account create \
                            --name "$STORAGE_NAME" \
                            --resource-group "$RESOURCE_GROUP" \
                            --enable-hierarchical-namespace &>/dev/null; then
                            success=true
                            break
                        fi
                    done
                    if [ "$success" = false ]; then
                        log_error "Failed to find available Storage Account name after $max_attempts attempts"
                        return 1
                    fi
                    ;;
                *)
                    STORAGE_NAME="$action"
                    ;;
            esac
        else
            success=true
            continue
        fi

        if [ "$success" = false ]; then
            log_info "Creating Storage Account $STORAGE_NAME..."
            if az storage account create \
                --name "$STORAGE_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --enable-hierarchical-namespace; then
                success=true
                log_success "Storage Account $STORAGE_NAME created successfully"
            else
                if ! az storage account show --name "$STORAGE_NAME" &>/dev/null; then
                    log_error "Failed to create Storage Account"
                    return 1
                fi
            fi
        fi
    done

    log_success "Azure resources created successfully"
    return 0
}

################################################################################
# Summary and Main Functions
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

# Main execution function
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
    
    # Check for existing Arc cluster
    local skip_arc=false
    if check_existing_arc_cluster "$RESOURCE_GROUP" ""; then
        skip_arc=true
        log_info "Using existing Arc-enabled cluster"
    fi
    
    # Only get new resource names if needed
    if [ -z "$CLUSTER_NAME" ] || [ -z "$AKV_NAME" ] || [ -z "$STORAGE_NAME" ]; then
        time_action "Get Resource Names" get_resource_names || exit 1
    fi
    
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
    
    if [ "$skip_arc" != "true" ]; then
        time_action "Setup Connected K8s" setup_connectedk8s || exit 1
        time_action "Configure K3s OIDC" configure_k3s_oidc || exit 1
    fi
    
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