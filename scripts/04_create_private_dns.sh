#!/bin/bash

# ==== CONFIGURATION ====
RG_NAME="az104-learn-dns-rg1"
VNET_NAME="vnet1"
DNS_ZONE_NAME="az104lab.internal"
JUMPBOX_VM_NAME="jumpbox-vm"
VMSS_NAME="web-vmss"

# DNS Records to Create
JUMPBOX_RECORD="jumpbox"
WEB_RECORD="web"
API_RECORD="api"
LB_RECORD="loadbalancer"
APPGW_RECORD="appgateway"

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
log_info "Starting Azure Private DNS Zone setup..."

# Check if Azure CLI is logged in
if ! az account show &> /dev/null; then
    log_error "Please log in to Azure CLI first: az login"
    exit 1
fi

# Check if resource group exists
if ! az group show --name $RG_NAME &> /dev/null; then
    log_error "Resource group '$RG_NAME' does not exist."
    exit 1
fi

# Check if VNet exists
if ! az network vnet show --resource-group $RG_NAME --name $VNET_NAME &> /dev/null; then
    log_error "Virtual network '$VNET_NAME' does not exist."
    exit 1
fi

log_success "All prerequisites validated"

# ==== 1. Create Private DNS Zone ====
log_info "Creating Private DNS Zone: $DNS_ZONE_NAME"
if az network private-dns zone show --resource-group $RG_NAME --name $DNS_ZONE_NAME &> /dev/null; then
    log_warning "Private DNS Zone '$DNS_ZONE_NAME' already exists, skipping creation"
else
    az network private-dns zone create \
        --resource-group $RG_NAME \
        --name $DNS_ZONE_NAME \
        --tags Environment=Learning Project=AZ104 Purpose=PrivateDNS
    log_success "Private DNS Zone created"
fi

# ==== 2. Link Private DNS Zone to VNet ====
log_info "Linking DNS Zone to VNet: $VNET_NAME"
LINK_NAME="${VNET_NAME}-link"

if az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE_NAME --name $LINK_NAME &> /dev/null; then
    log_warning "VNet link '$LINK_NAME' already exists, skipping creation"
else
    az network private-dns link vnet create \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --name $LINK_NAME \
        --virtual-network $VNET_NAME \
        --registration-enabled true \
        --tags Environment=Learning Project=AZ104
    log_success "VNet linked to Private DNS Zone"
fi

# ==== 3. Get IP Addresses of Existing Resources ====
log_info "Retrieving IP addresses of existing resources..."

# Get Jump Box private IP
JUMPBOX_PRIVATE_IP=$(az vm list-ip-addresses --resource-group $RG_NAME --name $JUMPBOX_VM_NAME \
    --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)

# Get VMSS instance private IP
VMSS_PRIVATE_IP=$(az vm list --resource-group $RG_NAME --query "[?contains(name, '$VMSS_NAME')].name" -o tsv | \
    head -1 | xargs -I {} az vm list-ip-addresses --resource-group $RG_NAME --name {} \
    --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)

# Get Load Balancer public IP
LB_PUBLIC_IP=$(az network public-ip show --resource-group $RG_NAME --name web-vmss-lb-pip \
    --query ipAddress -o tsv 2>/dev/null)

# Get Application Gateway public IP
APPGW_PUBLIC_IP=$(az network public-ip show --resource-group $RG_NAME --name webapp-gw-publicip \
    --query ipAddress -o tsv 2>/dev/null)

log_info "Found IP addresses:"
echo "   Jump Box Private IP:      $JUMPBOX_PRIVATE_IP"
echo "   VMSS Private IP:          $VMSS_PRIVATE_IP"
echo "   Load Balancer Public IP:  $LB_PUBLIC_IP"
echo "   App Gateway Public IP:    $APPGW_PUBLIC_IP"

# ==== 4. Create DNS A Records ====
log_info "Creating DNS A records..."

# Jump Box record
if [ -n "$JUMPBOX_PRIVATE_IP" ] && [ "$JUMPBOX_PRIVATE_IP" != "null" ]; then
    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name $JUMPBOX_RECORD \
        --ipv4-address $JUMPBOX_PRIVATE_IP 2>/dev/null || \
    log_warning "Jump box DNS record might already exist"
    log_success "Created: $JUMPBOX_RECORD.$DNS_ZONE_NAME → $JUMPBOX_PRIVATE_IP"
fi

# Web/VMSS record (private IP)
if [ -n "$VMSS_PRIVATE_IP" ] && [ "$VMSS_PRIVATE_IP" != "null" ]; then
    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name $WEB_RECORD \
        --ipv4-address $VMSS_PRIVATE_IP 2>/dev/null || \
    log_warning "Web DNS record might already exist"
    log_success "Created: $WEB_RECORD.$DNS_ZONE_NAME → $VMSS_PRIVATE_IP"
fi

# Load Balancer record (public IP - for external access)
if [ -n "$LB_PUBLIC_IP" ] && [ "$LB_PUBLIC_IP" != "null" ]; then
    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name $LB_RECORD \
        --ipv4-address $LB_PUBLIC_IP 2>/dev/null || \
    log_warning "Load balancer DNS record might already exist"
    log_success "Created: $LB_RECORD.$DNS_ZONE_NAME → $LB_PUBLIC_IP"
fi

# Application Gateway record (public IP)
if [ -n "$APPGW_PUBLIC_IP" ] && [ "$APPGW_PUBLIC_IP" != "null" ]; then
    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name $APPGW_RECORD \
        --ipv4-address $APPGW_PUBLIC_IP 2>/dev/null || \
    log_warning "Application Gateway DNS record might already exist"
    log_success "Created: $APPGW_RECORD.$DNS_ZONE_NAME → $APPGW_PUBLIC_IP"
fi

# ==== 5. Create CNAME Records for Services ====
log_info "Creating CNAME records for services..."

# API endpoint pointing to Application Gateway
az network private-dns record-set cname set-record \
    --resource-group $RG_NAME \
    --zone-name $DNS_ZONE_NAME \
    --record-set-name $API_RECORD \
    --cname $APPGW_RECORD.$DNS_ZONE_NAME 2>/dev/null || \
log_warning "API CNAME record might already exist"
log_success "Created: $API_RECORD.$DNS_ZONE_NAME → $APPGW_RECORD.$DNS_ZONE_NAME"

# Create additional service aliases
SERVICES=("frontend" "backend" "admin" "monitor")
for service in "${SERVICES[@]}"; do
    az network private-dns record-set cname set-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name $service \
        --cname $APPGW_RECORD.$DNS_ZONE_NAME 2>/dev/null || true
done
log_success "Created service aliases: frontend, backend, admin, monitor"

# ==== 6. Create TXT Records for Documentation ====
log_info "Creating TXT records for documentation..."
az network private-dns record-set txt add-record \
    --resource-group $RG_NAME \
    --zone-name $DNS_ZONE_NAME \
    --record-set-name "_lab-info" \
    --value "AZ-104 Learning Lab - Created $(date)" 2>/dev/null || true

az network private-dns record-set txt add-record \
    --resource-group $RG_NAME \
    --zone-name $DNS_ZONE_NAME \
    --record-set-name "_architecture" \
    --value "Jump Box + VMSS + Load Balancer + Application Gateway + Private DNS" 2>/dev/null || true

# ==== 7. Configure VNet DNS Settings ====
log_info "Configuring VNet to use Azure DNS..."
az network vnet update \
    --resource-group $RG_NAME \
    --name $VNET_NAME \
    --dns-servers "" 2>/dev/null || log_warning "VNet DNS settings might already be configured"

# ==== 8. Test DNS Resolution ====
log_info "Testing DNS resolution..."

# Create a test script for the jump box
cat > /tmp/dns_test.sh << 'EOF'
#!/bin/bash
echo "=== DNS Resolution Test ==="
echo "Testing from $(hostname):"
echo

# Test internal records
echo "1. Internal DNS Resolution:"
for record in jumpbox web loadbalancer appgateway api frontend; do
    result=$(nslookup $record.az104lab.internal 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
    if [ -n "$result" ]; then
        echo "   ✓ $record.az104lab.internal → $result"
    else
        echo "   ✗ $record.az104lab.internal → Failed"
    fi
done

echo
echo "2. External DNS (should still work):"
nslookup google.com | grep -A1 "Name:" | tail -1 | awk '{print "   ✓ google.com →", $2}'

echo
echo "3. Reverse DNS lookup:"
local_ip=$(hostname -I | awk '{print $1}')
echo "   Local IP: $local_ip"
reverse=$(nslookup $local_ip 2>/dev/null | grep "name =" | awk '{print $4}')
if [ -n "$reverse" ]; then
    echo "   ✓ Reverse lookup: $local_ip → $reverse"
else
    echo "   ○ Reverse lookup: Not configured (normal for lab)"
fi

echo
echo "=== DNS Test Complete ==="
EOF

chmod +x /tmp/dns_test.sh

# ==== 9. Output Summary ====
echo
echo "=========================================="
log_success "PRIVATE DNS ZONE SETUP COMPLETE"
echo "=========================================="
echo
echo "PRIVATE DNS ZONE:"
echo "   Zone Name:      $DNS_ZONE_NAME"
echo "   Resource Group: $RG_NAME"
echo "   VNet Link:      $LINK_NAME (Auto-registration enabled)"
echo
echo "DNS RECORDS CREATED:"
echo "   A Records:"
if [ -n "$JUMPBOX_PRIVATE_IP" ]; then
    echo "   ├─ $JUMPBOX_RECORD.$DNS_ZONE_NAME → $JUMPBOX_PRIVATE_IP"
fi
if [ -n "$VMSS_PRIVATE_IP" ]; then
    echo "   ├─ $WEB_RECORD.$DNS_ZONE_NAME → $VMSS_PRIVATE_IP"
fi
if [ -n "$LB_PUBLIC_IP" ]; then
    echo "   ├─ $LB_RECORD.$DNS_ZONE_NAME → $LB_PUBLIC_IP"
fi
if [ -n "$APPGW_PUBLIC_IP" ]; then
    echo "   └─ $APPGW_RECORD.$DNS_ZONE_NAME → $APPGW_PUBLIC_IP"
fi
echo
echo "   CNAME Records:"
echo "   ├─ $API_RECORD.$DNS_ZONE_NAME → $APPGW_RECORD.$DNS_ZONE_NAME"
echo "   ├─ frontend.$DNS_ZONE_NAME → $APPGW_RECORD.$DNS_ZONE_NAME"
echo "   ├─ backend.$DNS_ZONE_NAME → $APPGW_RECORD.$DNS_ZONE_NAME"
echo "   ├─ admin.$DNS_ZONE_NAME → $APPGW_RECORD.$DNS_ZONE_NAME"
echo "   └─ monitor.$DNS_ZONE_NAME → $APPGW_RECORD.$DNS_ZONE_NAME"
echo
echo "TESTING COMMANDS:"
echo "   SSH using DNS:     ssh -i ~/.ssh/az104-learn-dns-secure-jumpbox-key azuser@$JUMPBOX_RECORD.$DNS_ZONE_NAME"
echo "   Web via DNS:       curl http://$WEB_RECORD.$DNS_ZONE_NAME"
echo "   Load Balancer:     curl http://$LB_RECORD.$DNS_ZONE_NAME"
echo "   Application GW:    curl http://$APPGW_RECORD.$DNS_ZONE_NAME"
echo "   API Endpoint:      curl http://$API_RECORD.$DNS_ZONE_NAME"
echo
echo "DNS TESTING:"
echo "   Copy test script to jump box:"
echo "   scp -i ~/.ssh/az104-learn-dns-secure-jumpbox-key /tmp/dns_test.sh azuser@$JUMPBOX_RECORD.$DNS_ZONE_NAME:~/"
echo "   ssh -i ~/.ssh/az104-learn-dns-secure-jumpbox-key azuser@$JUMPBOX_RECORD.$DNS_ZONE_NAME"
echo "   ./dns_test.sh"
echo
echo "AZURE PORTAL:"
echo "   View DNS Zone: Portal → Private DNS zones → $DNS_ZONE_NAME"
echo "   Monitor queries: Portal → Private DNS zones → $DNS_ZONE_NAME → Metrics"
echo
echo "LEARNING SCENARIOS:"
echo "   1. Test name resolution from different VMs"
echo "   2. Add/modify DNS records for new services"
echo "   3. Experiment with TTL values"
echo "   4. Monitor DNS query metrics"
echo "   5. Practice conditional forwarding scenarios"
echo
echo "AZ-104 EXAM TOPICS COVERED:"
echo "   ✓ Private DNS zones"
echo "   ✓ VNet integration"
echo "   ✓ DNS record types (A, CNAME, TXT)"
echo "   ✓ Auto-registration"
echo "   ✓ Service discovery patterns"
echo "=========================================="

# Clean up temporary files
rm -f /tmp/dns_test.sh
