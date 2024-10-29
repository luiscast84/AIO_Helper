#!/bin/bash

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Function to validate and format resource names
validate_name() {
    local input=$1
    local prefix=$2
    local max_length=$3
    
    # Convert to lowercase and remove spaces
    local formatted=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    
    # Ensure it starts with letter and contains only letters and numbers
    if [[ ! $formatted =~ ^[a-z][a-z0-9]*$ ]]; then
        print_error "Name must start with a letter and contain only letters and numbers"
        return 1
    fi
    
    # Check length including prefix
    if [ ${#formatted} -gt $max_length ]; then
        print_error "Name too long (max $max_length characters including prefix)"
        return 1
    fi
    
    echo "$formatted"
    return 0
}

# Function to check if Azure CLI is logged in
check_azure_login() {
    if ! az account show >/dev/null 2>&1; then
        print_info "Please log in to Azure..."
        az login
    fi
}

# Function to get available locations
get_locations() {
    az account list-locations --query "[].name" -o tsv
}

# Function to validate location
validate_location() {
    local location=$1
    local locations=$(get_locations)
    if [[ $locations == *"$location"* ]]; then
        return 0
    else
        return 1
    fi
}

# Main script starts here
print_section "Azure Resource Setup for LAB460"
print_info "This script will help you set up Azure resources for Arc-enabled Kubernetes"

# Check Azure CLI login
check_azure_login

# Get subscription ID
print_section "Subscription Selection"
az account list --query "[].{name:name, id:id}" -o table
echo
read -p "Enter your subscription ID: " SUBSCRIPTION_ID
az account set --subscription $SUBSCRIPTION_ID

# Get location
print_section "Location Selection"
print_info "Available locations:"
az account list-locations --query "[].name" -o table
echo
while true; do
    read -p "Enter the Azure location: " LOCATION
    LOCATION=$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')
    if validate_location "$LOCATION"; then
        break
    else
        print_error "Invalid location. Please choose from the list above."
    fi
done

# Set resource group
RESOURCE_GROUP="lab460"
print_success "Using resource group: $RESOURCE_GROUP"

# Get cluster name
print_section "Cluster Configuration"
while true; do
    read -p "Enter the Arc-enabled cluster name: " CLUSTER_NAME
    CLUSTER_NAME=$(validate_name "$CLUSTER_NAME" "" 63)
    if [ $? -eq 0 ]; then
        break
    fi
done

# Get storage account name
print_section "Storage Account Configuration"
while true; do
    read -p "Enter the storage account name (without 'st' suffix): " STORAGE_BASE
    STORAGE_NAME="${STORAGE_BASE}st"
    STORAGE_NAME=$(validate_name "$STORAGE_NAME" "" 24)
    if [ $? -eq 0 ]; then
        break
    fi
done

# Get Key Vault name
print_section "Key Vault Configuration"
while true; do
    read -p "Enter the Key Vault name (without 'akv' suffix): " KV_BASE
    AKV_NAME="${KV_BASE}akv"
    AKV_NAME=$(validate_name "$AKV_NAME" "" 24)
    if [ $? -eq 0 ]; then
        break
    fi
done

# Summary before execution
print_section "Configuration Summary"
echo "Subscription ID: $SUBSCRIPTION_ID"
echo "Location: $LOCATION"
echo "Resource Group: $RESOURCE_GROUP"
echo "Cluster Name: $CLUSTER_NAME"
echo "Storage Account: $STORAGE_NAME"
echo "Key Vault: $AKV_NAME"

read -p "Press Enter to continue or Ctrl+C to cancel..."

# Execute Azure commands
print_section "Registering Azure Providers"
PROVIDERS=(
    "Microsoft.ExtendedLocation"
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.IoTOperations"
    "Microsoft.DeviceRegistry"
    "Microsoft.SecretSyncController"
)

for provider in "${PROVIDERS[@]}"; do
    print_info "Registering $provider..."
    az provider register -n "$provider"
done

print_section "Installing Azure Extensions"
print_info "Adding connectedk8s extension..."
az extension add --upgrade --name connectedk8s

# Create resource group if it doesn't exist
print_section "Creating Resource Group"
az group create --name $RESOURCE_GROUP --location $LOCATION

# Connect the cluster
print_section "Connecting Kubernetes Cluster"
print_info "Connecting cluster to Azure Arc..."
az connectedk8s connect \
    --name $CLUSTER_NAME \
    -l $LOCATION \
    --resource-group $RESOURCE_GROUP \
    --subscription $SUBSCRIPTION_ID \
    --enable-oidc-issuer \
    --enable-workload-identity

# Get OIDC Issuer URL
print_info "Getting OIDC Issuer URL..."
export ISSUER_URL_ID=$(az connectedk8s show \
    --resource-group $RESOURCE_GROUP \
    --name $CLUSTER_NAME \
    --query oidcIssuerProfile.issuerUrl \
    --output tsv)

print_section "Configuring K3s Service Account"
# Update K3s configuration
{
    echo "kube-apiserver-arg:"
    echo " - service-account-issuer=$ISSUER_URL_ID"
    echo " - service-account-max-token-expiration=24h"
} | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null

# Enable features
print_section "Enabling Arc Features"
print_info "Getting Object ID..."
export OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)

print_info "Enabling cluster features..."
az connectedk8s enable-features \
    -n $CLUSTER_NAME \
    -g $RESOURCE_GROUP \
    --custom-locations-oid $OBJECT_ID \
    --features cluster-connect custom-locations

print_info "Restarting K3s..."
sudo systemctl restart k3s

# Create Key Vault
print_section "Creating Key Vault"
print_info "Creating Key Vault $AKV_NAME..."
AKV_RESULT=$(az keyvault create \
    --enable-rbac-authorization \
    --name $AKV_NAME \
    --resource-group $RESOURCE_GROUP)
export AKV_ID=$(echo $AKV_RESULT | jq -r '.id')

# Create Storage Account
print_section "Creating Storage Account"
print_info "Creating Storage Account $STORAGE_NAME..."
az storage account create \
    --name $STORAGE_NAME \
    --resource-group $RESOURCE_GROUP \
    --enable-hierarchical-namespace

print_section "Setup Complete"
print_success "Azure resources have been created successfully"
print_info "Key Vault ID: $AKV_ID"
print_info "Please save these values for future use"

# Save variables to a file
print_section "Saving Configuration"
CONFIG_FILE="azure_config.env"
{
    echo "export SUBSCRIPTION_ID=\"$SUBSCRIPTION_ID\""
    echo "export LOCATION=\"$LOCATION\""
    echo "export RESOURCE_GROUP=\"$RESOURCE_GROUP\""
    echo "export CLUSTER_NAME=\"$CLUSTER_NAME\""
    echo "export STORAGE_NAME=\"$STORAGE_NAME\""
    echo "export AKV_NAME=\"$AKV_NAME\""
    echo "export AKV_ID=\"$AKV_ID\""
    echo "export ISSUER_URL_ID=\"$ISSUER_URL_ID\""
} > $CONFIG_FILE

print_success "Configuration saved to $CONFIG_FILE"
print_info "To load these variables in a new session, run: source $CONFIG_FILE"