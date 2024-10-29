#!/bin/bash

################################################################################
# Azure Resource Setup Script
# 
# This script automates the setup of Azure resources for Arc-enabled Kubernetes.
# It handles:
# - Azure login and subscription management
# - Resource group verification/creation
# - Provider registration
# - Kubernetes cluster connection
# - Storage and Key Vault creation
#
# The script includes timing, error handling, and status reporting.
################################################################################

# Color definitions for pretty output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
readonly SCRIPT_START_TIME=$(date +%s)
declare -A ACTION_TIMES
readonly RESOURCE_GROUP="LAB460"  # Fixed resource group name

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

################################################################################
# Utility Functions
################################################################################

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

################################################################################
# Azure Authentication and Setup Functions
################################################################################

# Function to check Azure login status
check_azure_login() {
    log_info "Checking Azure login status..."
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
        
        read -p "Would you like to use this subscription? (Y/n): " use_current
        if [[ -z "$use_current" || "${use_current,,}" == "y"* ]]; then
            SUBSCRIPTION_ID=$current_sub
            log_success "Using current subscription: $SUBSCRIPTION_ID"
            return 0
        fi
    fi

    # If user wants to change or no subscription is set
    log_info "Available subscriptions:"
    az account list --query "[].{Name:name, ID:id, State:state}" -o table
    
    while true; do
        read -p "Enter Subscription ID (or press Enter to cancel): " SUBSCRIPTION_ID
        
        # Allow user to cancel and keep current subscription
        if [[ -z "$SUBSCRIPTION_ID" && -n "$current_sub" ]]; then
            SUBSCRIPTION_ID=$current_sub
            log_success "Keeping current subscription: $SUBSCRIPTION_ID"
            return 0
        fi
        
        # Validate and set the new subscription
        if az account show --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
            az account set --subscription "$SUBSCRIPTION_ID"
            log_success "Switched to subscription: $SUBSCRIPTION_ID"
            break
        else
            log_error "Invalid subscription ID. Please try again."
        fi
    done
}

################################################################################
# Resource Group and Location Management
################################################################################

# Function to check resource group existence and location
check_resource_group() {
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

# Function to get and validate location
get_location() {
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
# Resource Name Input Functions
################################################################################

# Function to get cluster name
get_cluster_name() {
    while true; do
        read -p "Enter cluster name (lowercase, no spaces): " CLUSTER_NAME
        CLUSTER_NAME=$(format_text "$CLUSTER_NAME")
        if [[ $CLUSTER_NAME =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
            break
        else
            log_error "Invalid cluster name. Use lowercase letters, numbers, and hyphens."
        fi
    done
}

# Function to get storage account name
get_storage_name() {
    while true; do
        read -p "Enter storage account name (3-24 chars, lowercase letters and numbers): " STORAGE_NAME
        STORAGE_NAME=$(format_text "${STORAGE_NAME}st")
        if [[ $STORAGE_NAME =~ ^[a-z0-9]{3,24}$ ]]; then
            break
        else
            log_error "Invalid storage account name."
        fi
    done
}

# Function to get key vault name
get_keyvault_name() {
    while true; do
        read -p "Enter key vault name (3-24 chars, lowercase letters and numbers): " AKV_NAME
        AKV_NAME=$(format_text "${AKV_NAME}akv")
        if [[ $AKV_NAME =~ ^[a-z0-9-]{3,24}$ ]]; then
            break
        else
            log_error "Invalid key vault name."
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
    
    # Double-check all providers are registered
    local all_registered=true
    for provider in "${providers[@]}"; do
        local status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
        if [ "$status" != "Registered" ]; then
            log_error "$provider is not fully registered (status: $status)"
            all_registered=false
        fi
    done
    
    if [ "$all_registered" = false ]; then
        log_error "Not all providers are fully registered. Please try running the script again."
        return 1
    fi
    
    log_success "All providers successfully registered"
    return 0
}

################################################################################
# Kubernetes Setup Functions
################################################################################

# Function to verify kubeconfig
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
    
    # Copy and merge kubeconfig
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

# Updated setup_connectedk8s function
setup_connectedk8s() {
    log_info "Setting up connected Kubernetes..."
    
    # Verify kubeconfig first
    if ! verify_kubeconfig; then
        log_error "Failed to verify Kubernetes configuration"
        return 1
    fi
    
    # Verify all required providers are registered first
    log_info "Verifying provider registration status..."
    local required_providers=(
        "Microsoft.Kubernetes"
        "Microsoft.KubernetesConfiguration"
        "Microsoft.ExtendedLocation"
    )
    
    for provider in "${required_providers[@]}"; do
        local status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
        if [ "$status" != "Registered" ]; then
            log_error "$provider is not fully registered (status: $status)"
            log_info "Please wait a few minutes and try again"
            return 1
        fi
    done
    
    # Add extension if not present
    if ! az extension show --name connectedk8s &>/dev/null; then
        time_action "Add connectedk8s extension" az extension add --upgrade --name connectedk8s || {
            log_error "Failed to add connectedk8s extension"
            return 1
        }
    fi
    
    # Verify kubectl context
    log_info "Verifying kubectl context..."
    kubectl config use-context default
    
    # Connect cluster with additional error handling
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
        log_info "Checking kubeconfig..."
        kubectl config view
        return 1
    }
    
    # Get OIDC Issuer URL
    ISSUER_URL_ID=$(az connectedk8s show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --query oidcIssuerProfile.issuerUrl \
        --output tsv)
}

# Also update the configure_k3s function to ensure proper setup
configure_k3s() {
    log_info "Configuring k3s..."
    
    # Backup existing config if it exists
    if [ -f /etc/rancher/k3s/config.yaml ]; then
        sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.bak
        log_info "Backed up existing k3s configuration"
    fi
    
    # Create or update k3s config
    {
        echo "kube-apiserver-arg:"
        echo " - service-account-issuer=$ISSUER_URL_ID"
        echo " - service-account-max-token-expiration=24h"
    } | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
    
    # Get Object ID and enable features
    OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
    
    # Restart k3s and wait for it to be ready
    log_info "Restarting k3s..."
    sudo systemctl restart k3s
    
    # Wait for k3s to be ready
    log_info "Waiting for k3s to be ready..."
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if kubectl cluster-info &>/dev/null; then
            log_success "k3s is ready"
            break
        fi
        log_info "Attempt $attempt/$max_attempts: Waiting for k3s to be ready..."
        sleep 10
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log_error "k3s did not become ready in time"
        return 1
    fi
    
    # Enable cluster features
    time_action "Enable cluster features" az connectedk8s enable-features \
        -n "$CLUSTER_NAME" \
        -g "$RESOURCE_GROUP" \
        --custom-locations-oid "$OBJECT_ID" \
        --features cluster-connect custom-locations || {
        log_error "Failed to enable cluster features"
        return 1
    }
}


################################################################################
# Azure Resource Creation Functions
################################################################################

# Function to create Azure resources
create_azure_resources() {
    # Create Key Vault
    log_info "Creating Key Vault..."
    local kvResult=$(time_action "Create Key Vault" az keyvault create \
        --enable-rbac-authorization \
        --name "$AKV_NAME" \
        --resource-group "$RESOURCE_GROUP")
    AKV_ID=$(echo "$kvResult" | jq -r '.id')
    
    # Create Storage Account
    log_info "Creating Storage Account..."
    time_action "Create Storage Account" az storage account create \
        --name "$STORAGE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --enable-hierarchical-namespace || {
        log_error "Failed to create storage account"
        return 1
    }
}

################################################################################
# Summary and Configuration Functions
################################################################################

# Function to print summary
print_summary() {
    local end_time=$(date +%s)
    local total_time=$((end_time - SCRIPT_START_TIME))
    
    echo -e "\n${BLUE}=== Execution Summary ===${NC}"
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
    
    # Essential setup
    check_azure_login || exit 1
    check_resource_group || exit 1
    get_subscription || exit 1
    get_cluster_name || exit 1
    get_storage_name || exit 1
    get_keyvault_name || exit 1
    
    # Show configuration before proceeding
    echo -e "\n${BLUE}=== Configuration to be applied ===${NC}"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Storage Account: $STORAGE_NAME"
    echo "Key Vault: $AKV_NAME"
    
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    
    # Execute Azure operations with progress tracking and error handling
    log_info "Starting Azure resource setup..."
    
    # Register providers with progress indication
    log_info "Step 1/4: Registering Azure providers"
    if ! register_providers; then
        log_error "Provider registration failed. Please check the errors above."
        exit 1
    fi
    
    # Setup connected kubernetes
    log_info "Step 2/4: Setting up connected Kubernetes"
    if ! setup_connectedk8s; then
        log_error "Kubernetes setup failed. Please check the errors above."
        exit 1
    fi
    
    # Configure k3s
    log_info "Step 3/4: Configuring k3s"
    if ! configure_k3s; then
        log_error "k3s configuration failed. Please check the errors above."
        exit 1
    fi
    
    # Create Azure resources
    log_info "Step 4/4: Creating Azure resources"
    if ! create_azure_resources; then
        log_error "Resource creation failed. Please check the errors above."
        exit 1
    fi
    
    # Print summary of all operations
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

# Exit with success
exit 0