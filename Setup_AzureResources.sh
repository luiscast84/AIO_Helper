#!/bin/bash

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timing and tracking variables
START_TIME=$(date +%s)
declare -A OPERATION_TIMES=()
declare -A OPERATION_STATUS=()

# Fixed variables
RG_NAME="LAB460"
LOCATION="westus2"

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

# Function to print info messages
print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to track operation timing
track_operation() {
    local operation=$1
    local start_time=$(date +%s)
    
    # Execute the command and store its output and exit status
    local output
    output=$("${@:2}" 2>&1)
    local status=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    OPERATION_TIMES[$operation]=$duration
    if [ $status -eq 0 ]; then
        OPERATION_STATUS[$operation]="SUCCESS"
        print_success "$operation completed in $duration seconds"
    else
        OPERATION_STATUS[$operation]="FAILED"
        print_error "$operation failed after $duration seconds"
        echo "Error output: $output"
    fi
    
    return $status
}

# Function to handle Azure authentication and subscription
handle_azure_auth() {
    print_section "Azure Authentication"
    
    # Ensure DISPLAY is set for GUI applications
    if [ -z "$DISPLAY" ]; then
        export DISPLAY=:0
    fi

    # First check if already logged in
    print_info "Checking current Azure login status..."
    local account_info
    account_info=$(az account show 2>/dev/null)
    if [ $? -ne 0 ]; then
        print_info "Not logged in. Starting Azure login process..."
        print_info "Opening browser for authentication... (If browser doesn't open, run 'az login' manually)"
        
        if ! az login; then
            print_error "Azure login failed"
            print_info "Please try running 'az login' manually"
            exit 1
        fi
        
        # Get updated account info after login
        account_info=$(az account show)
    fi

    # Verify subscription info
    SUBSCRIPTION_ID=$(echo "$account_info" | jq -r .id)
    SUBSCRIPTION_NAME=$(echo "$account_info" | jq -r .name)
    TENANT_ID=$(echo "$account_info" | jq -r .tenantId)
    USER_NAME=$(echo "$account_info" | jq -r .user.name)

    if [[ -z "$SUBSCRIPTION_ID" || "$SUBSCRIPTION_ID" == "null" ]]; then
        print_error "No subscription information found"
        print_error "Please make sure you have an active subscription"
        exit 1
    fi

    print_success "Successfully authenticated with Azure"
    print_info "Active Subscription Details:"
    print_info "Subscription Name   : $SUBSCRIPTION_NAME"
    print_info "Subscription ID     : $SUBSCRIPTION_ID"
    print_info "Tenant ID          : $TENANT_ID"
    print_info "User               : $USER_NAME"

    # Ensure subscription is set as active
    if ! az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
        print_error "Failed to set subscription as active"
        exit 1
    fi
    print_success "Successfully set active subscription"
    
    export SUBSCRIPTION_ID
}

# Main script starts here
print_section "Azure Arc Cluster Setup"
print_info "Setting up Azure Arc environment in $LOCATION"

# Check Azure CLI installation
if ! command -v az >/dev/null 2>&1; then
    print_error "Azure CLI is not installed. Please install it first."
    exit 1
fi

# Check jq installation
if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is not installed. Installing..."
    sudo apt-get update && sudo apt-get install -y jq
    if [ $? -ne 0 ]; then
        print_error "Failed to install jq. Please install it manually."
        exit 1
    fi
fi

# Handle Azure authentication
handle_azure_auth

# Generate resource names (lowercase)
CLUSTER_NAME="${RG_NAME,,}-cluster"
STORAGE_NAME="${RG_NAME,,}st"
AKV_NAME="${RG_NAME,,}akv"

# Show configuration
print_section "Configuration"
print_info "Resource Group: $RG_NAME"
print_info "Location: $LOCATION"
print_info "Cluster Name: $CLUSTER_NAME"
print_info "Storage Account: $STORAGE_NAME"
print_info "Key Vault: $AKV_NAME"

# Register providers
print_section "Registering Azure Providers"
providers=(
    "Microsoft.ExtendedLocation"
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.IoTOperations"
    "Microsoft.DeviceRegistry"
    "Microsoft.SecretSyncController"
)

for provider in "${providers[@]}"; do
    print_info "Registering provider: $provider"
    track_operation "Register $provider" az provider register -n "$provider" --wait
done

# Add/upgrade extensions
print_section "Installing Azure CLI Extensions"
track_operation "Install connectedk8s extension" az extension add --upgrade --name connectedk8s

# Create resource group
print_section "Creating Resource Group"
track_operation "Create Resource Group" az group create --name $RG_NAME --location $LOCATION

# Connect cluster to Arc
print_section "Connecting Cluster to Arc"
track_operation "Connect to Arc" az connectedk8s connect \
    --name $CLUSTER_NAME \
    -l $LOCATION \
    --resource-group $RG_NAME \
    --subscription $SUBSCRIPTION_ID \
    --enable-oidc-issuer \
    --enable-workload-identity

# Get OIDC issuer URL
print_section "Configuring OIDC"
ISSUER_URL_ID=$(az connectedk8s show \
    --resource-group $RG_NAME \
    --name $CLUSTER_NAME \
    --subscription $SUBSCRIPTION_ID \
    --query oidcIssuerProfile.issuerUrl \
    --output tsv)

# Configure k3s service account
print_section "Configuring K3s Service Account"
{
    echo "kube-apiserver-arg:"
    echo " - service-account-issuer=$ISSUER_URL_ID"
    echo " - service-account-max-token-expiration=24h"
} | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null

# Enable features
print_section "Enabling Arc Features"
OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
track_operation "Enable Arc Features" az connectedk8s enable-features \
    -n $CLUSTER_NAME \
    -g $RG_NAME \
    --subscription $SUBSCRIPTION_ID \
    --custom-locations-oid $OBJECT_ID \
    --features cluster-connect custom-locations

# Restart k3s
print_section "Restarting K3s"
track_operation "Restart k3s" systemctl restart k3s

# Create Key Vault
print_section "Creating Key Vault"
track_operation "Create Key Vault" az keyvault create \
    --enable-rbac-authorization \
    --name $AKV_NAME \
    --resource-group $RG_NAME \
    --subscription $SUBSCRIPTION_ID \
    --location $LOCATION

# Create Storage Account
print_section "Creating Storage Account"
track_operation "Create Storage Account" az storage account create \
    --name $STORAGE_NAME \
    --resource-group $RG_NAME \
    --subscription $SUBSCRIPTION_ID \
    --location $LOCATION \
    --enable-hierarchical-namespace

# Save environment variables
print_section "Saving Environment Variables"
cat << EOF > ./azure-resources.env
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export RESOURCE_GROUP="$RG_NAME"
export LOCATION="$LOCATION"
export CLUSTER_NAME="$CLUSTER_NAME"
export STORAGE_NAME="$STORAGE_NAME"
export AKV_NAME="$AKV_NAME"
export ISSUER_URL_ID="$ISSUER_URL_ID"
EOF

# Print completion time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

print_section "Setup Complete"
print_success "Azure Arc cluster setup completed"
print_info "Environment variables saved to ./azure-resources.env"
print_info "To load variables, run: source ./azure-resources.env"
print_info "Total setup time: $(($DURATION / 60)) minutes and $(($DURATION % 60)) seconds"

# Print operation summary
print_section "Operation Summary"
for operation in "${!OPERATION_TIMES[@]}"; do
    status_color=$RED
    if [ "${OPERATION_STATUS[$operation]}" == "SUCCESS" ]; then
        status_color=$GREEN
    fi
    echo -e "Operation: $operation"
    echo -e "Status: ${status_color}${OPERATION_STATUS[$operation]}${NC}"
    echo -e "Time: ${OPERATION_TIMES[$operation]} seconds"
    echo "---"
done