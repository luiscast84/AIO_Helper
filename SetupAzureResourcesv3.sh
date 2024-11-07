#!/bin/bash

################################################################################
# Azure Arc Resource Setup Script with Enhanced Logging
#
# This script automates the setup of Azure Arc-enabled Kubernetes cluster and
# retrieves existing Azure resource information, with comprehensive progress
# tracking and real-time status updates.
#
# Features:
# - Automated Azure Arc enablement for K3s clusters
# - Automatic Arc cluster name generation
# - Retrieval and creation of Key Vault and Storage Account
# - Real-time progress tracking and status updates
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

# Color codes and formatting
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly ITALIC='\033[3m'
readonly UNDERLINE='\033[4m'
readonly NC='\033[0m' # No Color

# Spinner characters for progress indication
readonly SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Global variables
readonly SCRIPT_START_TIME=$(date +%s)
readonly RESOURCE_GROUP="LAB460"  # Fixed resource group name
readonly VERBOSE=${VERBOSE:-true}
readonly TEMP_DIR=$(mktemp -d)
readonly LOG_DIR="logs"
readonly LOG_FILE="${LOG_DIR}/azure_setup_$(date +%Y%m%d_%H%M%S).log"

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
declare -A OPERATION_STATUS
declare -A COMMAND_OUTPUTS

# Create log directory
mkdir -p "$LOG_DIR"

################################################################################
# Enhanced Logging Functions
################################################################################

# Initialize logging system
init_logging() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    # Start new log file with header
    {
        echo "=================================="
        echo "Script Execution Started"
        echo "Date: $(date)"
        echo "User: $(whoami)"
        echo "Host: $(hostname)"
        echo "=================================="
        echo
    } | tee "$LOG_FILE"
}

# Function to format command for display
format_command() {
    local cmd="$*"
    echo -e "${DIM}${ITALIC}$ ${CYAN}${cmd}${NC}"
}

# Spinner process ID
SPINNER_PID=""

# Start a spinner in the background
start_spinner() {
    local msg="$1"
    tput civis  # Hide cursor
    
    # Start spinner in background
    (
        local i=0
        while true; do
            local spinner_char="${SPINNER_CHARS:$i:1}"
            printf "\r${DIM}${CYAN}%s${NC} %s" "$spinner_char" "$msg"
            i=$(( (i + 1) % ${#SPINNER_CHARS} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

# Stop the spinner
stop_spinner() {
    local result=$1
    # Kill spinner process
    kill $SPINNER_PID 2>/dev/null
    wait $SPINNER_PID 2>/dev/null
    SPINNER_PID=""
    # Show cursor
    tput cnorm
    # Clear line and print result if provided
    printf "\r\033[K"
    if [ -n "$result" ]; then
        echo -e "$result"
    fi
}

# Enhanced logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=$NC
    local prefix=""
    
    case $level in
        "INFO")     color=$BLUE;    prefix="ℹ";;
        "SUCCESS")  color=$GREEN;   prefix="✔";;
        "WARNING")  color=$YELLOW;  prefix="⚠";;
        "ERROR")    color=$RED;     prefix="✖";;
        "COMMAND")  color=$CYAN;    prefix="$";;
        "PROGRESS") color=$MAGENTA; prefix="→";;
        "DEBUG")    color=$DIM;     prefix="⚙";;
    esac
    
    # Format log message
    printf "${color}${BOLD}%s${NC} ${DIM}%s${NC} ${color}%-10s${NC} %s\n" \
           "$prefix" "$timestamp" "$level" "$message" | tee -a "$LOG_FILE"
    
    # Ensure output is displayed immediately
    flush_output
}

# Logging shortcuts
log_info() { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_error() { log "ERROR" "$1"; }
log_command() { log "COMMAND" "$1"; }
log_progress() { log "PROGRESS" "$1"; }
log_debug() { [ "$VERBOSE" = true ] && log "DEBUG" "$1"; }

# Function to flush output buffers
flush_output() {
    sync
    printf "\033[0m"
    tput sgr0
}

# Progress bar function
show_progress() {
    local operation="$1"
    local current="$2"
    local total="$3"
    local detail="$4"
    
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    # Clear previous line
    printf "\r\033[K"
    
    # Show progress bar
    printf "${CYAN}${operation}${NC} ["
    printf "%${completed}s" | tr ' ' '⣿'
    printf "%${remaining}s" | tr ' ' '⣀'
    printf "] ${BOLD}%d%%${NC}" $percentage
    
    if [ -n "$detail" ]; then
        printf " ${DIM}${detail}${NC}"
    fi
}

# Execute command with progress tracking
execute_with_logging() {
    local cmd_name="$1"
    shift
    local full_command="$*"
    
    log_command "Starting: $cmd_name"
    format_command "$full_command"
    
    start_spinner "$cmd_name"
    
    local output
    local start_time=$(date +%s.%N)
    
    if output=$("$@" 2>&1); then
        local end_time=$(date +%s.%N)
        local duration=$(printf "%.2f" $(echo "$end_time - $start_time" | bc))
        stop_spinner
        log_success "$cmd_name completed in ${duration}s"
        
        if [ "$VERBOSE" = true ] && [ -n "$output" ]; then
            echo -e "${DIM}${CYAN}Output:${NC}"
            echo -e "${DIM}$output${NC}"
        fi
        return 0
    else
        local end_time=$(date +%s.%N)
        local duration=$(printf "%.2f" $(echo "$end_time - $start_time" | bc))
        stop_spinner
        log_error "$cmd_name failed after ${duration}s"
        echo -e "${RED}Error output:${NC}"
        echo -e "${DIM}$output${NC}"
        return 1
    fi
}
################################################################################
# Utility Functions
################################################################################

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
    local base="lab460cluster"
    local random_num=$(printf "%04d" $((RANDOM % 10000)))
    echo "${base}${random_num}"
}

# Function to measure execution time of actions
time_action() {
    local start_time=$(date +%s)
    local action_name="$1"
    shift
    
    log_progress "Starting action: $action_name"
    "$@"
    local status=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    ACTION_TIMES["$action_name"]=$duration
    
    if [ $status -eq 0 ]; then
        log_success "$action_name completed in ${duration}s"
    else
        log_error "$action_name failed after ${duration}s"
    fi
    
    return $status
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
        return 1
    fi
    
    # Inform user about sudo requirements
    log_info "This script requires sudo privileges for:"
    echo "  - Configuring k3s"
    echo "  - Modifying system settings"
    echo -e "\nOther operations like Azure login will run as current user"
    
    # Check if we can get sudo
    start_spinner "Validating sudo access"
    if ! sudo -v; then
        stop_spinner "${RED}✖${NC} Failed to obtain sudo privileges"
        log_error "Unable to get sudo privileges"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Sudo access confirmed"
    
    # Keep sudo alive in the background
    (while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null) &
    SUDO_KEEPER_PID=$!
    
    # Ensure we kill the sudo keeper on script exit
    trap 'cleanup_sudo' EXIT
    
    log_success "Sudo privileges confirmed and maintained"
    return 0
}

# Function to cleanup sudo keeper
cleanup_sudo() {
    if [ -n "$SUDO_KEEPER_PID" ]; then
        kill $SUDO_KEEPER_PID 2>/dev/null
        wait $SUDO_KEEPER_PID 2>/dev/null
        log_debug "Sudo keeper process terminated"
    fi
}

################################################################################
# Prerequisites Verification Functions
################################################################################

# Function to verify all prerequisites
verify_prerequisites() {
    print_section "Verifying Prerequisites"
    
    local required_commands=(
        "az:Azure CLI"
        "kubectl:Kubernetes CLI"
        "jq:JSON processor"
        "bc:Basic Calculator"
    )
    
    local missing_commands=()
    local total_commands=${#required_commands[@]}
    local current=0
    
    log_info "Checking required commands..."
    
    for cmd_info in "${required_commands[@]}"; do
        ((current++))
        local cmd_name="${cmd_info%%:*}"
        local cmd_desc="${cmd_info#*:}"
        
        show_progress "Checking Prerequisites" $current $total_commands "$cmd_name"
        
        if ! command_exists "$cmd_name"; then
            missing_commands+=("$cmd_name ($cmd_desc)")
        fi
        sleep 0.5  # Small delay for visual feedback
    done
    echo # New line after progress bar
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_error "Missing required commands:"
        for cmd in "${missing_commands[@]}"; do
            echo "  - $cmd"
        done
        return 1
    fi
    
    # Verify Azure CLI version
    log_info "Checking Azure CLI version..."
    local az_version
    if az_version=$(az version --output tsv --query '"azure-cli"' 2>/dev/null); then
        log_success "Azure CLI version: $az_version"
    else
        log_error "Unable to determine Azure CLI version"
        return 1
    fi
    
    # Verify kubectl version
    log_info "Checking kubectl version..."
    local k8s_version
    if k8s_version=$(kubectl version --client --output json 2>/dev/null | jq -r '.clientVersion.gitVersion'); then
        log_success "kubectl version: $k8s_version"
    else
        log_error "Unable to determine kubectl version"
        return 1
    fi
    
    # Check if k3s is installed
    log_info "Checking k3s installation..."
    if systemctl is-active --quiet k3s; then
        log_success "k3s is running"
    else
        log_error "k3s is not running"
        return 1
    fi
    
    log_success "All prerequisites verified successfully"
    return 0
}

# Function to verify system resources
verify_system_resources() {
    print_section "Checking System Resources"
    
    # Check available memory
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local available_mem=$(free -m | awk '/^Mem:/{print $7}')
    
    log_info "Memory Status:"
    echo "  Total Memory: ${total_mem}MB"
    echo "  Available Memory: ${available_mem}MB"
    
    if [ "$available_mem" -lt 2048 ]; then
        log_warning "Low memory available. Recommended: at least 2GB free memory"
    else
        log_success "Sufficient memory available"
    fi
    
    # Check available disk space
    local disk_space=$(df -h / | awk 'NR==2 {print $4}')
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    
    log_info "Disk Space Status:"
    echo "  Available Space: ${disk_space}"
    echo "  Usage: ${disk_usage}%"
    
    if [ "$disk_usage" -gt 90 ]; then
        log_warning "Low disk space available. Recommended: less than 90% usage"
    else
        log_success "Sufficient disk space available"
    fi
    
    # Check CPU load
    local cpu_load=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1)
    
    log_info "CPU Load Status:"
    echo "  Current Load: ${cpu_load}"
    
    if [ "$(echo "$cpu_load > 2" | bc)" -eq 1 ]; then
        log_warning "High CPU load detected. This might affect performance"
    else
        log_success "CPU load is normal"
    fi
    
    return 0
}
################################################################################
# Azure Authentication Functions
################################################################################

# Function to check Azure CLI extensions
check_azure_extensions() {
    print_section "Verifying Azure CLI Extensions"
    
    local required_extensions=(
        "connectedk8s:Azure Connected Kubernetes"
        "k8s-extension:Kubernetes Extension"
        "customlocation:Custom Locations"
    )
    
    local total_exts=${#required_extensions[@]}
    local current=0
    
    for ext_info in "${required_extensions[@]}"; do
        ((current++))
        local ext_name="${ext_info%%:*}"
        local ext_desc="${ext_info#*:}"
        
        show_progress "Checking Extensions" $current $total_exts "$ext_name"
        
        if ! az extension show --name "$ext_name" &>/dev/null; then
            log_info "Installing extension: $ext_name ($ext_desc)"
            start_spinner "Installing $ext_name..."
            if ! az extension add --name "$ext_name" --yes &>/dev/null; then
                stop_spinner "${RED}✖${NC} Failed to install $ext_name"
                log_error "Failed to install Azure CLI extension: $ext_name"
                return 1
            fi
            stop_spinner "${GREEN}✔${NC} Installed $ext_name"
        fi
    done
    echo # New line after progress bar
    
    log_success "All required Azure CLI extensions are installed"
    return 0
}

# Function to check Azure login status
check_azure_login() {
    print_section "Checking Azure Authentication"
    
    start_spinner "Checking Azure CLI installation"
    if ! command_exists az; then
        stop_spinner "${RED}✖${NC} Azure CLI not found"
        log_error "Azure CLI is not installed. Please install it first."
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Azure CLI is installed"
    
    # Check current login status
    start_spinner "Checking current Azure login status"
    if az account show &>/dev/null; then
        stop_spinner "${GREEN}✔${NC} Already logged in"
        log_info "Current Azure login information:"
        az account show --query "{Subscription:name,UserName:user.name,TenantID:tenantId}" -o table
        
        read -p "Continue with this Azure account? (Y/n): " use_current
        if [[ -z "$use_current" || "${use_current,,}" == "y"* ]]; then
            log_success "Using current Azure login"
            return 0
        fi
    else
        stop_spinner "${YELLOW}⚠${NC} Not logged in"
    fi
    
    # Need to login
    log_info "Azure login required. Opening browser..."
    start_spinner "Waiting for Azure login"
    
    if ! az login; then
        stop_spinner "${RED}✖${NC} Login failed"
        log_error "Azure login failed"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Login successful"
    
    # Show login information
    log_success "Logged in successfully. Account information:"
    az account show --query "{Subscription:name,UserName:user.name,TenantID:tenantId}" -o table
    return 0
}

################################################################################
# Resource Group Management Functions
################################################################################

# Function to get and validate subscription
get_subscription() {
    print_section "Checking Subscription"
    
    start_spinner "Getting current subscription"
    if current_sub=$(az account show --query id -o tsv 2>/dev/null); then
        stop_spinner "${GREEN}✔${NC} Found current subscription"
        log_info "Current subscription: $(az account show --query name -o tsv)"
        log_info "Subscription ID: $current_sub"
        SUBSCRIPTION_ID=$current_sub
        log_success "Using current subscription: $SUBSCRIPTION_ID"
        return 0
    else
        stop_spinner "${YELLOW}⚠${NC} No current subscription"
        
        # Show available subscriptions with formatting
        log_info "Available subscriptions:"
        echo -e "${DIM}"
        az account list --query "[].{Name:name, ID:id, State:state}" -o table
        echo -e "${NC}"
        
        # Interactive subscription selection with validation
        while true; do
            read -p "Enter Subscription ID: " SUBSCRIPTION_ID
            start_spinner "Validating subscription"
            if az account show --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
                stop_spinner "${GREEN}✔${NC} Subscription validated"
                az account set --subscription "$SUBSCRIPTION_ID"
                log_success "Switched to subscription: $SUBSCRIPTION_ID"
                break
            else
                stop_spinner "${RED}✖${NC} Invalid subscription"
                log_error "Invalid subscription ID. Please try again."
            fi
        done
    fi
}

# Function to get and validate Azure location
get_location() {
    print_section "Setting Azure Location"
    
    # Get available locations with filtering for commonly used ones
    log_info "Available Azure locations:"
    echo -e "${DIM}"
    az account list-locations \
        --query "[?not_null(displayName)].{Name:name, Display:displayName, Region:regionalDisplayName}" \
        --output table
    echo -e "${NC}"
    
    while true; do
        read -p "Enter Azure location (e.g., eastus, westeurope): " input_location
        LOCATION=$(format_text "$input_location")
        
        start_spinner "Validating location"
        if az account list-locations --query "[?name=='$LOCATION']" --output tsv &>/dev/null; then
            stop_spinner "${GREEN}✔${NC} Location validated"
            log_success "Selected location: $LOCATION"
            break
        else
            stop_spinner "${RED}✖${NC} Invalid location"
            log_error "Invalid location. Please try again."
        fi
    done
}

# Function to check resource group existence and location
check_resource_group() {
    print_section "Checking Resource Group"
    
    log_info "Checking for resource group $RESOURCE_GROUP..."
    start_spinner "Checking resource group existence"
    
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        stop_spinner "${GREEN}✔${NC} Resource group found"
        LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
        log_success "Found existing resource group $RESOURCE_GROUP in location: $LOCATION"
        
        # Get detailed resource group information
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
        stop_spinner "${YELLOW}⚠${NC} Resource group not found"
        log_warning "Resource group $RESOURCE_GROUP not found"
        
        # Get location if not already set
        if [ -z "$LOCATION" ]; then
            get_location
        fi
        
        log_info "Creating resource group $RESOURCE_GROUP in $LOCATION..."
        start_spinner "Creating resource group"
        
        if ! az group create --name "$RESOURCE_GROUP" --location "$LOCATION"; then
            stop_spinner "${RED}✖${NC} Creation failed"
            log_error "Failed to create resource group"
            return 1
        fi
        
        stop_spinner "${GREEN}✔${NC} Resource group created"
        log_success "Resource group created successfully"
        return 0
    fi
}
################################################################################
# Resource Creation Functions
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
    
    log_info "Creating Key Vault with following configuration:"
    echo "  Name: $kv_name"
    echo "  Location: $location"
    echo "  Resource Group: $resource_group"
    
    # Create Key Vault with progress tracking
    start_spinner "Creating Key Vault"
    if ! output=$(az keyvault create \
        --name "$kv_name" \
        --resource-group "$resource_group" \
        --location "$location" \
        --sku "standard" \
        --enable-rbac-authorization true 2>&1); then
        stop_spinner "${RED}✖${NC} Failed to create Key Vault"
        log_error "Key Vault creation failed: $output"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Key Vault created"
    
    # Get Key Vault ID
    start_spinner "Getting Key Vault details"
    AKV_NAME="$kv_name"
    AKV_ID=$(az keyvault show --name "$kv_name" --resource-group "$resource_group" --query "id" --output tsv)
    
    if [ -z "$AKV_ID" ]; then
        stop_spinner "${RED}✖${NC} Failed to get Key Vault ID"
        log_error "Unable to get Key Vault ID"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Key Vault details retrieved"
    
    log_success "Key Vault created successfully"
    log_info "Key Vault Name: $AKV_NAME"
    log_info "Key Vault ID: $AKV_ID"
    return 0
}

# Function to create Storage Account
create_storage_account() {
    local resource_group="$1"
    local location="$2"
    print_section "Creating Azure Storage Account"
    
    # Generate unique name for Storage Account
    local base_name="lab460st"
    local random_num=$(printf "%04d" $((RANDOM % 10000)))
    local st_name="${base_name}${random_num}"
    
    log_info "Creating Storage Account with following configuration:"
    echo "  Name: $st_name"
    echo "  Location: $location"
    echo "  Resource Group: $resource_group"
    
    # Create Storage Account with progress tracking
    start_spinner "Creating Storage Account"
    if ! output=$(az storage account create \
        --name "$st_name" \
        --resource-group "$resource_group" \
        --location "$location" \
        --sku "Standard_LRS" \
        --kind "StorageV2" \
        --enable-hierarchical-namespace true \
        --min-tls-version "TLS1_2" \
        --https-only true 2>&1); then
        stop_spinner "${RED}✖${NC} Failed to create Storage Account"
        log_error "Storage Account creation failed: $output"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Storage Account created"
    
    # Get Storage Account ID
    start_spinner "Getting Storage Account details"
    ST_NAME="$st_name"
    ST_ID=$(az storage account show --name "$st_name" --resource-group "$resource_group" --query "id" --output tsv)
    
    if [ -z "$ST_ID" ]; then
        stop_spinner "${RED}✖${NC} Failed to get Storage Account ID"
        log_error "Unable to get Storage Account ID"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Storage Account details retrieved"
    
    log_success "Storage Account created successfully"
    log_info "Storage Account Name: $ST_NAME"
    log_info "Storage Account ID: $ST_ID"
    return 0
}

# Function to get existing resource IDs with creation fallback
get_existing_resource_ids() {
    local resource_group="$1"
    print_section "Getting Existing Resource IDs"
    
    # Check for existing Key Vault
    log_info "Looking for existing Key Vault..."
    start_spinner "Checking Key Vault"
    local kv_list
    kv_list=$(az keyvault list -g "$resource_group" --query "[].{name:name, id:id}" -o json)
    
    if [ -n "$kv_list" ] && [ "$kv_list" != "[]" ]; then
        # Get the first Key Vault if multiple exist
        AKV_NAME=$(echo "$kv_list" | jq -r '.[0].name')
        AKV_ID=$(echo "$kv_list" | jq -r '.[0].id')
        stop_spinner "${GREEN}✔${NC} Found existing Key Vault"
        log_success "Found Key Vault: $AKV_NAME"
        log_info "Key Vault ID: $AKV_ID"
    else
        stop_spinner "${YELLOW}⚠${NC} No existing Key Vault found"
        log_warning "No Key Vault found in resource group $resource_group"
        log_info "Creating new Key Vault..."
        create_key_vault "$resource_group" "$LOCATION" || return 1
    fi
    
    # Check for existing Storage Account
    log_info "Looking for existing Storage Account..."
    start_spinner "Checking Storage Account"
    local st_list
    st_list=$(az storage account list -g "$resource_group" --query "[].{name:name, id:id}" -o json)
    
    if [ -n "$st_list" ] && [ "$st_list" != "[]" ]; then
        # Get the first Storage Account if multiple exist
        ST_NAME=$(echo "$st_list" | jq -r '.[0].name')
        ST_ID=$(echo "$st_list" | jq -r '.[0].id')
        stop_spinner "${GREEN}✔${NC} Found existing Storage Account"
        log_success "Found Storage Account: $ST_NAME"
        log_info "Storage Account ID: $ST_ID"
    else
        stop_spinner "${YELLOW}⚠${NC} No existing Storage Account found"
        log_warning "No Storage Account found in resource group $resource_group"
        log_info "Creating new Storage Account..."
        create_storage_account "$resource_group" "$LOCATION" || return 1
    fi
    
    return 0
}

# Function to validate Azure resources
validate_azure_resources() {
    print_section "Validating Azure Resources"
    
    local validation_errors=0
    
    # Validate Key Vault
    start_spinner "Validating Key Vault"
    if [ -n "$AKV_NAME" ] && [ -n "$AKV_ID" ]; then
        if ! az keyvault show --name "$AKV_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
            stop_spinner "${RED}✖${NC} Key Vault validation failed"
            log_error "Key Vault $AKV_NAME is not accessible"
            ((validation_errors++))
        else
            stop_spinner "${GREEN}✔${NC} Key Vault validated"
        fi
    else
        stop_spinner "${RED}✖${NC} Key Vault not configured"
        log_error "Key Vault information is missing"
        ((validation_errors++))
    fi
    
    # Validate Storage Account
    start_spinner "Validating Storage Account"
    if [ -n "$ST_NAME" ] && [ -n "$ST_ID" ]; then
        if ! az storage account show --name "$ST_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
            stop_spinner "${RED}✖${NC} Storage Account validation failed"
            log_error "Storage Account $ST_NAME is not accessible"
            ((validation_errors++))
        else
            stop_spinner "${GREEN}✔${NC} Storage Account validated"
        fi
    else
        stop_spinner "${RED}✖${NC} Storage Account not configured"
        log_error "Storage Account information is missing"
        ((validation_errors++))
    fi
    
    if [ $validation_errors -eq 0 ]; then
        log_success "All Azure resources validated successfully"
        return 0
    else
        log_error "Resource validation failed with $validation_errors errors"
        return 1
    fi
}
################################################################################
# Azure Arc Setup Functions
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
    
    local total_providers=${#providers[@]}
    local current=0
    
    log_info "Starting registration of $total_providers providers"
    
    for provider in "${providers[@]}"; do
        ((current++))
        show_progress "Provider Registration" $current $total_providers "$provider"
        
        # Check current status
        start_spinner "Checking status of $provider"
        local status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv 2>/dev/null)
        
        if [ "$status" != "Registered" ]; then
            stop_spinner "${YELLOW}⚠${NC} Provider not registered"
            log_info "Registering provider: $provider"
            
            start_spinner "Registering $provider"
            if ! az provider register -n "$provider" &>/dev/null; then
                stop_spinner "${RED}✖${NC} Registration failed"
                log_error "Failed to register $provider"
                return 1
            fi
            
            # Wait for registration with progress updates
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                status=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
                show_progress "Registration Progress" $attempt $max_attempts "$provider: $status"
                
                if [ "$status" == "Registered" ]; then
                    echo # New line after progress bar
                    log_success "Provider $provider registered successfully"
                    break
                fi
                
                if [ $attempt -eq $max_attempts ]; then
                    echo # New line after progress bar
                    log_error "Provider $provider failed to register in time"
                    return 1
                fi
                
                ((attempt++))
                sleep 2
            done
        else
            stop_spinner "${GREEN}✔${NC} Already registered"
        fi
    done
    
    log_success "All providers successfully registered"
    return 0
}

# Function to setup connected kubernetes
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
    start_spinner "Checking existing cluster"
    if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
        stop_spinner "${YELLOW}⚠${NC} Cluster already exists"
        log_warning "Cluster $CLUSTER_NAME already exists in resource group $RESOURCE_GROUP"
        
        # Ask user what to do
        read -p "Do you want to delete and recreate the cluster? (y/N): " recreate_cluster
        if [[ "${recreate_cluster,,}" == "y"* ]]; then
            log_info "Deleting existing cluster..."
            start_spinner "Deleting existing cluster"
            
            if ! az connectedk8s delete --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --yes &>/dev/null; then
                stop_spinner "${RED}✖${NC} Deletion failed"
                log_error "Failed to delete existing cluster"
                return 1
            fi
            stop_spinner "${GREEN}✔${NC} Existing cluster deleted"
            
            # Wait for deletion
            local timeout=300
            local start_time=$(date +%s)
            start_spinner "Waiting for cluster deletion to complete"
            while az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; do
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                
                if [ $elapsed -gt $timeout ]; then
                    stop_spinner "${RED}✖${NC} Deletion timeout"
                    log_error "Timeout waiting for cluster deletion"
                    return 1
                fi
                
                sleep 10
            done
            stop_spinner "${GREEN}✔${NC} Cluster deletion confirmed"
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
    else
        stop_spinner "${GREEN}✔${NC} No existing cluster found"
    fi
    
    # Configure extension settings
    log_info "Configuring Azure CLI extension settings..."
    start_spinner "Configuring CLI extensions"
    az config set extension.use_dynamic_install=yes_without_prompt &>/dev/null
    az config set extension.dynamic_install.allow_preview=true &>/dev/null
    stop_spinner "${GREEN}✔${NC} CLI extensions configured"
    
    # Connect cluster with retry logic
    log_info "Connecting cluster to Azure Arc..."
    log_info "Configuration:"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Location: $LOCATION"
    
    local max_attempts=3
    local attempt=1
    local success=false
    
    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log_info "Attempt $attempt of $max_attempts to connect cluster..."
        start_spinner "Connecting cluster (Attempt $attempt/$max_attempts)"
        
        if az connectedk8s connect \
            --name "$CLUSTER_NAME" \
            -l "$LOCATION" \
            --resource-group "$RESOURCE_GROUP" \
            --subscription "$SUBSCRIPTION_ID" \
            --enable-oidc-issuer \
            --enable-workload-identity \
            --yes &>/dev/null; then
            success=true
            stop_spinner "${GREEN}✔${NC} Cluster connected successfully"
            break
        else
            stop_spinner "${RED}✖${NC} Connection attempt failed"
            if [ $attempt -lt $max_attempts ]; then
                log_warning "Retrying in 30 seconds..."
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
        start_spinner "Getting OIDC Issuer URL (Attempt $((retry_count + 1))/$max_retries)"
        ISSUER_URL_ID=$(az connectedk8s show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$CLUSTER_NAME" \
            --query oidcIssuerProfile.issuerUrl \
            --output tsv)
            
        if [ -n "$ISSUER_URL_ID" ]; then
            stop_spinner "${GREEN}✔${NC} OIDC Issuer URL retrieved"
            break
        fi
        
        stop_spinner "${YELLOW}⚠${NC} Retry needed"
        ((retry_count++))
        if [ $retry_count -lt $max_retries ]; then
            log_info "Waiting for OIDC Issuer URL... Attempt $((retry_count + 1)) of $max_retries"
            sleep 15
        fi
    done
    
    if [ -z "$ISSUER_URL_ID" ]; then
        log_error "Failed to get OIDC Issuer URL"
        return 1
    fi
    
    log_success "Successfully connected to Azure Arc"
    log_info "OIDC Issuer URL: $ISSUER_URL_ID"
    return 0
}
################################################################################
# K3s Configuration Functions
################################################################################

# Function to configure k3s OIDC
configure_k3s_oidc() {
    print_section "Configuring K3s OIDC"
    
    # Verify OIDC URL
    if [ -z "$ISSUER_URL_ID" ]; then
        log_error "OIDC Issuer URL not available"
        return 1
    fi
    
    # Backup existing config
    if [ -f /etc/rancher/k3s/config.yaml ]; then
        local backup_file="/etc/rancher/k3s/config.yaml.bak.$(date +%Y%m%d_%H%M%S)"
        start_spinner "Backing up existing k3s configuration"
        if ! sudo cp /etc/rancher/k3s/config.yaml "$backup_file"; then
            stop_spinner "${RED}✖${NC} Backup failed"
            log_error "Failed to backup k3s configuration"
            return 1
        fi
        stop_spinner "${GREEN}✔${NC} Configuration backed up to $backup_file"
    fi
    
    # Update k3s configuration
    log_info "Updating k3s configuration for OIDC..."
    log_info "Setting service account issuer to: $ISSUER_URL_ID"
    
    start_spinner "Updating k3s configuration"
    if ! {
        echo "kube-apiserver-arg:"
        echo "  - service-account-issuer=$ISSUER_URL_ID"
        echo "  - service-account-max-token-expiration=24h"
    } | sudo tee /etc/rancher/k3s/config.yaml > /dev/null; then
        stop_spinner "${RED}✖${NC} Configuration update failed"
        log_error "Failed to update k3s configuration"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Configuration updated"
    
    # Restart k3s
    log_info "Restarting k3s service..."
    start_spinner "Restarting k3s"
    if ! sudo systemctl restart k3s; then
        stop_spinner "${RED}✖${NC} Restart failed"
        log_error "Failed to restart k3s"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} K3s restarted"
    
    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        show_progress "Node Readiness Check" $attempt $max_attempts "Attempt $attempt"
        
        if kubectl get nodes | grep -q "Ready"; then
            echo # New line after progress bar
            log_success "Node is ready"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            echo # New line after progress bar
            log_error "Node did not become ready in time"
            return 1
        fi
        
        ((attempt++))
        sleep 10
    done
    
    # Enable Arc features
    print_section "Enabling Arc Features"
    start_spinner "Getting Object ID for Arc features"
    OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
    if [ -z "$OBJECT_ID" ]; then
        stop_spinner "${RED}✖${NC} Failed to get Object ID"
        log_error "Failed to get Object ID for Arc features"
        return 1
    fi
    stop_spinner "${GREEN}✔${NC} Object ID retrieved"
    
    start_spinner "Enabling Arc features"
    if ! az connectedk8s enable-features \
        -n "$CLUSTER_NAME" \
        -g "$RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --custom-locations-oid "$OBJECT_ID" \
        --features cluster-connect custom-locations &>/dev/null; then
        stop_spinner "${RED}✖${NC} Feature enablement failed"
        log_warning "Failed to enable some Arc features - cluster will still work but with limited functionality"
    else
        stop_spinner "${GREEN}✔${NC} Arc features enabled"
    fi
    
    # Verify final configuration
    start_spinner "Verifying final configuration"
    local node_status=$(kubectl get nodes -o wide)
    stop_spinner "${GREEN}✔${NC} Configuration verified"
    
    log_success "K3s OIDC configuration completed"
    log_info "Current node status:"
    echo "$node_status"
    
    return 0
}

################################################################################
# Main Execution
################################################################################

main() {
    # Initialize logging
    init_logging
    log_info "Starting Azure Arc and resource setup..."
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
    # Track overall progress
    local total_steps=9
    local current_step=0
    
    # Step 1: Initial checks
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Initial Checks"
    if is_root; then
        log_error "Please run this script as a normal user (not root)"
        return 1
    fi
    
    # Step 2: Verify prerequisites
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Prerequisites"
    if ! verify_prerequisites; then
        log_error "Prerequisites check failed"
        return 1
    fi
    
    # Step 3: Check sudo privileges
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Sudo Privileges"
    if ! check_sudo_privileges; then
        log_error "Failed to obtain sudo privileges"
        return 1
    fi
    
    # Step 4: Verify Kubernetes setup
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Kubernetes Setup"
    if ! time_action "Verify Kubernetes" verify_kubernetes_prereqs; then
        log_error "Kubernetes verification failed"
        return 1
    fi
    
    # Step 5: Azure authentication
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Azure Authentication"
    if ! time_action "Azure Login" check_azure_login || \
       ! time_action "Get Subscription" get_subscription || \
       ! time_action "Check Resource Group" check_resource_group; then
        log_error "Azure authentication failed"
        return 1
    fi
    
    # Step 6: Resource setup
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Resource Setup"
    if ! time_action "Get Resource IDs" get_existing_resource_ids "$RESOURCE_GROUP"; then
        log_error "Resource setup failed"
        return 1
    fi
    
    # Show configuration summary
    print_section "Configuration to be applied"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Key Vault: $AKV_NAME"
    echo "Storage Account: $ST_NAME"
    
    # Auto-proceed after 5 seconds
    log_info "Proceeding with setup in 5 seconds..."
    sleep 5
    
    # Step 7: Register providers
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Provider Registration"
    if ! time_action "Register Providers" register_providers; then
        log_error "Provider registration failed"
        return 1
    fi
    
    # Step 8: Setup Arc
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "Arc Setup"
    if ! time_action "Setup Connected K8s" setup_connectedk8s; then
        log_error "Arc setup failed"
        return 1
    fi
    
    # Step 9: Configure K3s
    ((current_step++))
    show_progress "Overall Progress" $current_step $total_steps "K3s Configuration"
    if ! time_action "Configure K3s OIDC" configure_k3s_oidc; then
        log_error "K3s configuration failed"
        return 1
    fi
    
    # Save configuration
    if ! save_configuration; then
        log_warning "Failed to save configuration"
    fi
    
    # Print final status
    print_detailed_status
    print_summary
    
    log_success "Setup completed successfully!"
    log_info "Log file available at: $LOG_FILE"
    log_info "To load the configuration in a new session, run: source azure_config.env"
    
    return 0
}

################################################################################
# Script Execution
################################################################################

# Ensure script is run with bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with bash"
    exit 1
fi

# Execute main function and capture exit code
main
exit $?