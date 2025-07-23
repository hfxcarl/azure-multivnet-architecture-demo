#!/bin/bash


# ==== CONFIGURATION ====
RG_NAME="az104-learn-dns-rg1"
LOCATION="canadacentral"
VNET_NAME="vnet1"
SUBNET_NAME="subnet2"
VM_NAME="jumpbox-vm"
NSG_NAME="jumpbox-nsg"
USERNAME="azuser"
SSH_KEY_NAME="az104-learn-dns-secure-jumpbox-key"
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==== HELPER FUNCTIONS ====
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ==== VALIDATION ====
log_info "Starting Jump Box creation script..."

# Check if Azure CLI is logged in
if ! az account show &> /dev/null; then
    log_error "Please log in to Azure CLI first: az login"
    exit 1
fi

# Check if resource group exists
if ! az group show --name $RG_NAME &> /dev/null; then
    log_error "Resource group '$RG_NAME' does not exist. Please create it first."
    exit 1
fi

# Check if VNet exists
if ! az network vnet show --resource-group $RG_NAME --name $VNET_NAME &> /dev/null; then
    log_error "Virtual network '$VNET_NAME' does not exist in resource group '$RG_NAME'"
    exit 1
fi

# Check if subnet exists
if ! az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET_NAME --name $SUBNET_NAME &> /dev/null; then
    log_error "Subnet '$SUBNET_NAME' does not exist in VNet '$VNET_NAME'"
    exit 1
fi

log_success "All prerequisites validated"

# ==== 1. Generate SSH Key Pair ====
if [ ! -f "$SSH_KEY_PATH" ]; then
    log_info "Generating new SSH key pair at $SSH_KEY_PATH..."
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "$USERNAME@jumpbox"
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "$SSH_KEY_PATH.pub"
    log_success "SSH key pair generated"
else
    log_warning "SSH key already exists at $SSH_KEY_PATH, using existing key"
fi

# ==== 2. Create Network Security Group ====
log_info "Creating Network Security Group..."
if az network nsg show --resource-group $RG_NAME --name $NSG_NAME &> /dev/null; then
    log_warning "NSG '$NSG_NAME' already exists, skipping creation"
else
    az network nsg create \
        --resource-group $RG_NAME \
        --name $NSG_NAME \
        --location $LOCATION \
        --tags Role=JumpBox Environment=Learning Project=AZ104
    log_success "Network Security Group created"
fi

# ==== 3. Configure NSG Rules ====
log_info "Getting current public IP address..."
MY_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || curl -s --max-time 10 ipinfo.io/ip 2>/dev/null)

if [ -z "$MY_IP" ]; then
    log_error "Could not determine public IP address. Please check internet connection."
    exit 1
fi

log_info "Configuring SSH access from IP: $MY_IP"

# Create SSH rule (or update if exists)
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowSSHFromMyIP \
    --protocol Tcp \
    --direction Inbound \
    --priority 1000 \
    --source-address-prefixes "$MY_IP/32" \
    --destination-port-ranges 22 \
    --access Allow \
    --description "Allow SSH from current public IP: $MY_IP" 2>/dev/null || \
az network nsg rule update \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowSSHFromMyIP \
    --source-address-prefixes "$MY_IP/32" \
    --description "Allow SSH from current public IP: $MY_IP"

# Block all other SSH access
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name DenyAllSSH \
    --protocol Tcp \
    --direction Inbound \
    --priority 4000 \
    --source-address-prefixes "*" \
    --destination-port-ranges 22 \
    --access Deny \
    --description "Deny all other SSH access" 2>/dev/null || true

log_success "NSG rules configured"

# ==== 4. Get Subnet ID and Validate ====
log_info "Retrieving subnet information..."

# Get detailed subnet info for debugging
SUBNET_INFO=$(az network vnet subnet show \
    --resource-group $RG_NAME \
    --vnet-name $VNET_NAME \
    --name $SUBNET_NAME 2>/dev/null)

if [ -z "$SUBNET_INFO" ]; then
    log_error "Subnet '$SUBNET_NAME' not found or not accessible"
    log_info "Available subnets:"
    az network vnet subnet list --resource-group $RG_NAME --vnet-name $VNET_NAME --query '[].{Name:name,AddressPrefix:addressPrefix}' -o table
    exit 1
fi

SUBNET_ID=$(echo "$SUBNET_INFO" | jq -r '.id')
SUBNET_PREFIX=$(echo "$SUBNET_INFO" | jq -r '.addressPrefix')

if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "null" ]; then
    log_error "Could not retrieve valid subnet ID"
    exit 1
fi

log_success "Subnet ID retrieved: $SUBNET_ID"
log_info "Subnet address prefix: $SUBNET_PREFIX"

# ==== 5. Create Jump Box VM ====
log_info "Creating Jump Box VM..."

# Check if VM already exists
if az vm show --resource-group $RG_NAME --name $VM_NAME &> /dev/null; then
    log_warning "VM '$VM_NAME' already exists. Skipping VM creation."
    SKIP_VM=true
else
    SKIP_VM=false
fi

if [ "$SKIP_VM" = false ]; then
    az vm create \
        --resource-group $RG_NAME \
        --name $VM_NAME \
        --image Ubuntu2204 \
        --size Standard_B1s \
        --admin-username $USERNAME \
        --ssh-key-values "$SSH_KEY_PATH.pub" \
        --subnet $SUBNET_ID \
        --nsg $NSG_NAME \
        --public-ip-sku Standard \
        --public-ip-address-allocation Static \
        --storage-sku Standard_LRS \
        --os-disk-size-gb 30 \
        --tags Role=JumpBox Environment=Learning Project=AZ104 Owner=$USERNAME

    if [ $? -eq 0 ]; then
        log_success "Jump Box VM created successfully"
    else
        log_error "Failed to create Jump Box VM"
        exit 1
    fi
fi

# ==== 6. Get and Display Connection Information ====
log_info "Retrieving connection information..."

PUBLIC_IP=$(az vm list-ip-addresses \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --query "[].virtualMachine.network.publicIpAddresses[].ipAddress" -o tsv)

PRIVATE_IP=$(az vm list-ip-addresses \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --query "[].virtualMachine.network.privateIpAddresses[]" -o tsv)

# ==== 7. Output Summary ====
echo
echo "=========================================="
log_success "JUMP BOX SETUP COMPLETE"
echo "=========================================="
echo
echo "📋 CONNECTION DETAILS:"
echo "   Resource Group: $RG_NAME"
echo "   VM Name:        $VM_NAME"
echo "   Username:       $USERNAME"
echo "   Public IP:      $PUBLIC_IP"
echo "   Private IP:     $PRIVATE_IP"
echo "   SSH Key:        $SSH_KEY_PATH"
echo
echo "🔐 SSH CONNECTION COMMAND:"
echo "   ssh -i $SSH_KEY_PATH $USERNAME@$PUBLIC_IP"
echo
echo "📝 NEXT STEPS FOR AZ-104 LAB:"
echo "   1. Test SSH connection to jump box"
echo "   2. Create your VMSS in subnet1 for web servers"
echo "   3. Configure Application Gateway for load balancing"
echo "   4. Use this jump box to manage backend resources securely"
echo
echo "⚠️  SECURITY NOTES:"
echo "   - SSH access is restricted to your current IP: $MY_IP"
echo "   - Keep your private key secure: $SSH_KEY_PATH"
echo "   - Consider adding additional management tools to the jump box"
echo "=========================================="