#!/bin/bash

# Color definitions for pretty output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables for timing
readonly SCRIPT_START_TIME=$(date +%s)
declare -A ACTION_TIMES

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

# Function to check resource group existence and location
check_resource_group() {
    local rg="LAB460"
    log_info "Checking for resource group $rg..."
    
    if az group show --name "$rg" &>/dev/null; then
        LOCATION=$(az group show --name "$rg" --query location -o tsv)
        log_success "Found existing resource group $rg in location: $LOCATION"
        return 0
    else
        log_warning "Resource group $rg not found"
        get_location
        log_info "Creating resource group $rg in $LOCATION..."
        time_action "Create Resource Group" az group create --name "$rg" --location "$LOCATION" || {
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
        log_info "Registering provider: $provider"
        if ! az provider show --namespace "$provider" --query "registrationState" -o tsv | grep -q "Registered"; then
            time_action "Register $provider" az provider register -n "$provider" --wait || {
                log_error "Failed to register $provider"
                return 1
            }
        else
            log_info "$provider already registered"
        fi
    done
}

# Function to setup connectedk8s
setup_connectedk8s() {
    log_info "Setting up connected Kubernetes..."
    
    # Add extension if not present
    if ! az extension show --name connectedk8s &>/dev/null; then
        time_action "Add connectedk8s extension" az extension add --upgrade --name connectedk8s || {
            log_error "Failed to add connectedk8s extension"
            return 1
        }
    fi
    
    # Connect cluster
    time_action "Connect Kubernetes cluster" az connectedk8s connect \
        --name "$CLUSTER_NAME" \
        -l "$LOCATION" \
        --resource-group "LAB460" \
        --subscription "$SUBSCRIPTION_ID" \
        --enable-oidc-issuer \
        --enable-workload-identity || {
        log_error "Failed to connect Kubernetes cluster"
        return 1
    }
    
    # Get OIDC Issuer URL
    ISSUER_URL_ID=$(az connectedk8s show \
        --resource-group "LAB460" \
        --name "$CLUSTER_NAME" \
        --query oidcIssuerProfile.issuerUrl \
        --output tsv)
}

# Function to configure k3s
configure_k3s() {
    log_info "Configuring k3s..."
    {
        echo "kube-apiserver-arg:"
        echo " - service-account-issuer=$ISSUER_URL_ID"
        echo " - service-account-max-token-expiration=24h"
    } | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null
    
    # Get Object ID and enable features
    OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
    
    time_action "Enable cluster features" az connectedk8s enable-features \
        -n "$CLUSTER_NAME" \
        -g "LAB460" \
        --custom-locations-oid "$OBJECT_ID" \
        --features cluster-connect custom-locations || {
        log_error "Failed to enable cluster features"
        return 1
    }
    
    time_action "Restart k3s" sudo systemctl restart k3s || {
        log_error "Failed to restart k3s"
        return 1
    }
}

# Function to create Azure resources
create_azure_resources() {
    # Create Key Vault
    log_info "Creating Key Vault..."
    local kvResult=$(time_action "Create Key Vault" az keyvault create \
        --enable-rbac-authorization \
        --name "$AKV_NAME" \
        --resource-group "LAB460")
    AKV_ID=$(echo "$kvResult" | jq -r '.id')
    
    # Create Storage Account
    log_info "Creating Storage Account..."
    time_action "Create Storage Account" az storage account create \
        --name "$STORAGE_NAME" \
        --resource-group "LAB460" \
        --enable-hierarchical-namespace || {
        log_error "Failed to create storage account"
        return 1
    }
}

# Function to print summary
print_summary() {
    local end_time=$(date +%s)
    local total_time=$((end_time - SCRIPT_START_TIME))
    
    echo -e "\n${BLUE}=== Execution Summary ===${NC}"
    echo -e "\n${GREEN}Configuration:${NC}"
    echo "Resource Group: LAB460"
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
export RESOURCE_GROUP="LAB460"
export CLUSTER_NAME="$CLUSTER_NAME"
export STORAGE_NAME="$STORAGE_NAME"
export AKV_NAME="$AKV_NAME"
export AKV_ID="$AKV_ID"
export ISSUER_URL_ID="$ISSUER_URL_ID"
EOF
    log_success "Configuration saved to azure_config.env"
}

# Main execution flow
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
    echo "Resource Group: LAB460"
    echo "Location: $LOCATION"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Storage Account: $STORAGE_NAME"
    echo "Key Vault: $AKV_NAME"
    
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    
    # Execute Azure operations
    register_providers || exit 1
    setup_connectedk8s || exit 1
    configure_k3s || exit 1
    create_azure_resources || exit 1
    
    # Print summary
    print_summary
}

# Execute main function
main