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

# Function to format time
format_time() {
    local seconds=$1
    if ((seconds < 60)); then
        echo "${seconds}s"
    else
        local minutes=$((seconds/60))
        local remaining_seconds=$((seconds%60))
        echo "${minutes}m ${remaining_seconds}s"
    fi
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
        print_success "$operation completed in $(format_time $duration)"
    else
        OPERATION_STATUS[$operation]="FAILED"
        print_error "$operation failed after $(format_time $duration)"
        echo "Error output: $output"
    fi
    
    return $status
}

# Function to print timing summary
print_timing_summary() {
    print_section "Operation Timing Summary"
    
    local total_time=$(($(date +%s) - START_TIME))
    
    # Calculate the longest operation name for formatting
    local max_length=0
    for operation in "${!OPERATION_TIMES[@]}"; do
        local length=${#operation}
        if ((length > max_length)); then
            max_length=$length
        fi
    done
    
    # Print header
    printf "%-${max_length}s | %-8s | %-7s | %-s\n" "Operation" "Duration" "Status" "Details"
    printf "%${max_length}s-+-%8s-+-%7s-+-%s\n" | tr ' ' '-'
    
    # Print each operation
    for operation in "${!OPERATION_TIMES[@]}"; do
        local duration=$(format_time ${OPERATION_TIMES[$operation]})
        local status=${OPERATION_STATUS[$operation]}
        local status_color
        local details=""
        
        case $status in
            "SUCCESS")
                status_color=$GREEN
                ;;
            "FAILED")
                status_color=$RED
                ;;
            "SKIPPED")
                status_color=$YELLOW
                status="SKIPPED"
                ;;
        esac
        
        printf "%-${max_length}s | %-8s | ${status_color}%-7s${NC} | %s\n" \
            "$operation" "$duration" "$status" "$details"
    done
    
    # Print total time
    echo -e "\nTotal execution time: $(format_time $total_time)"
}

# Function to check Azure login status
check_azure_login() {
    print_section "Azure Authentication"
    
    # Try to get current account info silently
    if az account show >/dev/null 2>&1; then
        local sub_info=$(az account show)
        local sub_id=$(echo $sub_info | jq -r .id)
        local sub_name=$(echo $sub_info | jq -r .name)
        local tenant_id=$(echo $sub_info | jq -r .tenantId)
        
        print_success "Already logged in to Azure"
        print_info "Current subscription:"
        print_info "Name    : $sub_name"
        print_info "ID      : $sub_id"
        print_info "Tenant  : $tenant_id"
        
        OPERATION_STATUS["Azure Login"]="SKIPPED"
        echo "$sub_id"
        return 0
    else
        print_info "Not logged in to Azure."
        print_info "A browser window will open for authentication."
        print_info "Please complete the login process in your browser..."
        
        if ! track_operation "Azure Login" az login; then
            print_error "Azure login failed"
            return 1
        fi
        
        # Get subscription ID after successful login
        local sub_info=$(az account show)
        local sub_id=$(echo $sub_info | jq -r .id)
        echo "$sub_id"
        return 0
    fi
}

# Function to validate input
validate_input() {
    local input=$1
    local type=$2

    case $type in
        "location")
            # Convert to lowercase
            input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
            # Validate against common Azure locations
            if ! az account list-locations --query "[].name" -o tsv | grep -q "^$input$"; then
                print_error "Invalid Azure location"
                return 1
            fi
            ;;
        "resource_name")
            # Convert to lowercase and remove spaces for resource names
            input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
            # Validate resource name format
            if [[ ! $input =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
                print_error "Invalid resource name format"
                return 1
            fi
            ;;
    esac
    echo "$input"
    return 0
}

# Main script
print_section "Azure Arc Cluster Setup"
print_info "This script will help you set up an Arc-enabled Kubernetes cluster in Azure"

# Check Azure CLI installation
if ! command -v az >/dev/null 2>&1; then
    print_error "Azure CLI is not installed. Please install it first."
    exit 1
fi

# Check jq installation
if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is not installed. Please install it first with: sudo apt-get install jq"
    exit 1
fi

# Set resource group name (uppercase)
RG_NAME="LAB460"
print_success "Using resource group: $RG_NAME"

# Handle Azure login and get subscription
SUBSCRIPTION_ID=$(check_azure_login)
if [ $? -ne 0 ]; then
    print_error "Failed to authenticate with Azure"
    exit 1
fi

# Set subscription
track_operation "Set Subscription" az account set --subscription "$SUBSCRIPTION_ID"

# Get location
print_info "Available locations can be found using 'az account list-locations --query \"[].name\" -o tsv'"
LOCATION=$(validate_input "$(read -p 'Enter Azure region (e.g., eastus): ' loc && echo $loc)" "location")

# Generate lowercase resource names
CLUSTER_NAME="${RG_NAME,,}-cluster"  # Convert to lowercase
STORAGE_NAME="${RG_NAME,,}st"        # Convert to lowercase and add suffix
AKV_NAME="${RG_NAME,,}akv"          # Convert to lowercase and add suffix

# Confirm settings
print_section "Configuration Summary"
echo "Resource Group: $RG_NAME"
echo "Location: $LOCATION"
echo "Cluster Name: $CLUSTER_NAME"
echo "Storage Account Name: $STORAGE_NAME"
echo "Key Vault Name: $AKV_NAME"

read -p "Continue with these settings? (y/n): " confirm
if [[ $confirm != [yY] ]]; then
    print_info "Setup cancelled"
    exit 0
fi

# Register providers
print_section "Provider Registration"
PROVIDERS=(
    "Microsoft.ExtendedLocation"
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.IoTOperations"
    "Microsoft.DeviceRegistry"
    "Microsoft.SecretSyncController"
)

for provider in "${PROVIDERS[@]}"; do
    track_operation "Register $provider" az provider register -n "$provider" --wait
done

# Add/upgrade extensions
track_operation "Install connectedk8s extension" az extension add --upgrade --name connectedk8s

# Create resource group if it doesn't exist
if ! az group show --name $RG_NAME >/dev/null 2>&1; then
    track_operation "Create Resource Group" az group create --name $RG_NAME --location $LOCATION
else
    OPERATION_STATUS["Create Resource Group"]="SKIPPED"
    print_info "Resource group $RG_NAME already exists"
fi

# Connect cluster
track_operation "Connect to Arc" az connectedk8s connect \
    --name $CLUSTER_NAME \
    -l $LOCATION \
    --resource-group $RG_NAME \
    --subscription $SUBSCRIPTION_ID \
    --enable-oidc-issuer \
    --enable-workload-identity

# Get OIDC issuer URL
track_operation "Get OIDC URL" bash -c "ISSUER_URL_ID=\$(az connectedk8s show --resource-group $RG_NAME --name $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl --output tsv)"

# Configure k3s service account
track_operation "Configure k3s" bash -c '{
    echo "kube-apiserver-arg:"
    echo " - service-account-issuer=$ISSUER_URL_ID"
    echo " - service-account-max-token-expiration=24h"
} | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null'

# Enable features
track_operation "Enable Arc Features" bash -c 'OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv) && \
    az connectedk8s enable-features \
    -n $CLUSTER_NAME \
    -g $RG_NAME \
    --custom-locations-oid $OBJECT_ID \
    --features cluster-connect custom-locations'

# Restart k3s
track_operation "Restart k3s" systemctl restart k3s

# Create Key Vault
track_operation "Create Key Vault" az keyvault create \
    --enable-rbac-authorization \
    --name $AKV_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION

# Create Storage Account
track_operation "Create Storage Account" az storage account create \
    --name $STORAGE_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --enable-hierarchical-namespace

# Save environment variables
track_operation "Save Environment Variables" bash -c 'cat << EOF > ./azure-resources.env
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export LOCATION="$LOCATION"
export RESOURCE_GROUP="$RG_NAME"
export CLUSTER_NAME="$CLUSTER_NAME"
export STORAGE_NAME="$STORAGE_NAME"
export AKV_NAME="$AKV_NAME"
export ISSUER_URL_ID="$ISSUER_URL_ID"
EOF'

# Print timing summary
print_timing_summary

print_section "Setup Complete"
print_success "Azure Arc cluster setup completed successfully"
print_info "Environment variables have been saved to ./azure-resources.env"
print_info "To load these variables in future sessions, run: source ./azure-resources.env"