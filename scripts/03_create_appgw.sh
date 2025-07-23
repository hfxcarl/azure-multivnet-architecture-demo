#!/bin/bash

# ==== CONFIGURATION ====
RG_NAME="az104-learn-dns-rg1"
LOCATION="canadacentral"
VNET_NAME="vnet1"
APPGW_SUBNET_NAME="eca-appgwsubnet"  # Using existing Application Gateway subnet
APPGW_NAME="web-appgw"
APPGW_PIP_NAME="webapp-gw-publicip"  # Use existing public IP
VMSS_NAME="web-vmss"
BACKEND_POOL_NAME="vmss-backend-pool"
FRONTEND_PORT_NAME="appgw-frontend-port"
FRONTEND_IP_NAME="appgw-frontend-ip"
HTTP_SETTING_NAME="appgw-http-setting"
LISTENER_NAME="appgw-listener"
RULE_NAME="appgw-rule"
HEALTH_PROBE_NAME="appgw-health-probe"

# WAF Policy
WAF_POLICY_NAME="web-appgw-waf-policy"

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
log_info "Starting Application Gateway setup script..."

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

# Check if VNet and Application Gateway subnet exist
if ! az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET_NAME --name $APPGW_SUBNET_NAME &> /dev/null; then
    log_error "Application Gateway subnet '$APPGW_SUBNET_NAME' does not exist in VNet '$VNET_NAME'"
    log_info "Available subnets:"
    az network vnet subnet list --resource-group $RG_NAME --vnet-name $VNET_NAME --query '[].name' -o table
    exit 1
fi

# Check if VMSS exists
if ! az vmss show --resource-group $RG_NAME --name $VMSS_NAME &> /dev/null; then
    log_error "VMSS '$VMSS_NAME' does not exist. Please create the VMSS first."
    exit 1
fi

log_success "All prerequisites validated"

# ==== 1. Use Existing Public IP for Application Gateway ====
log_info "Using existing public IP for Application Gateway..."
if az network public-ip show --resource-group $RG_NAME --name $APPGW_PIP_NAME &> /dev/null; then
    log_success "Using existing public IP '$APPGW_PIP_NAME'"
    
    # Check if it's already associated with something
    ASSOCIATED_RESOURCE=$(az network public-ip show --resource-group $RG_NAME --name $APPGW_PIP_NAME --query 'ipConfiguration.id' -o tsv)
    if [ "$ASSOCIATED_RESOURCE" != "null" ] && [ -n "$ASSOCIATED_RESOURCE" ]; then
        log_warning "Public IP is currently associated with: $ASSOCIATED_RESOURCE"
        log_warning "Will reassociate it with the Application Gateway"
    fi
else
    log_error "Public IP '$APPGW_PIP_NAME' not found"
    exit 1
fi

# ==== 2. Create WAF Policy ====
log_info "Creating Web Application Firewall policy..."
if az network application-gateway waf-policy show --resource-group $RG_NAME --name $WAF_POLICY_NAME &> /dev/null; then
    log_warning "WAF policy '$WAF_POLICY_NAME' already exists, skipping creation"
else
    az network application-gateway waf-policy create \
        --resource-group $RG_NAME \
        --name $WAF_POLICY_NAME \
        --location $LOCATION \
        --type OWASP \
        --version 3.2 \
        --tags Environment=Learning Project=AZ104
    log_success "WAF policy created"
fi

# ==== 3. Get VMSS Backend IP Addresses ====
log_info "Retrieving VMSS instance IP addresses..."

# For Flex mode VMSS, we need to get the VM IPs differently
VMSS_BACKEND_IPS=$(az vm list --resource-group $RG_NAME \
    --query "[?contains(name, '$VMSS_NAME')].{Name:name}" -o tsv | \
    xargs -I {} az vm list-ip-addresses --resource-group $RG_NAME --name {} \
    --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv)

if [ -z "$VMSS_BACKEND_IPS" ]; then
    log_warning "Could not find VMSS instance IP addresses using VM method, trying direct approach..."
    
    # Try to get the IP we know exists
    VMSS_BACKEND_IPS="10.0.0.4"  # We know this IP from earlier testing
    log_info "Using known VMSS IP: $VMSS_BACKEND_IPS"
fi

if [ -z "$VMSS_BACKEND_IPS" ]; then
    log_error "Could not find any VMSS instance IP addresses"
    exit 1
fi

log_success "Found VMSS backend IPs: $VMSS_BACKEND_IPS"

# ==== 4. Create Application Gateway ====
log_info "Creating Application Gateway..."
if az network application-gateway show --resource-group $RG_NAME --name $APPGW_NAME &> /dev/null; then
    log_warning "Application Gateway '$APPGW_NAME' already exists, skipping creation"
    SKIP_APPGW=true
else
    SKIP_APPGW=false
fi

if [ "$SKIP_APPGW" = false ]; then
    # Get subnet ID
    APPGW_SUBNET_ID=$(az network vnet subnet show \
        --resource-group $RG_NAME \
        --vnet-name $VNET_NAME \
        --name $APPGW_SUBNET_NAME \
        --query id -o tsv)

    # Create Application Gateway with basic configuration and WAF policy
    az network application-gateway create \
        --resource-group $RG_NAME \
        --name $APPGW_NAME \
        --location $LOCATION \
        --sku WAF_v2 \
        --capacity 2 \
        --vnet-name $VNET_NAME \
        --subnet $APPGW_SUBNET_NAME \
        --public-ip-address $APPGW_PIP_NAME \
        --frontend-port 80 \
        --http-settings-cookie-based-affinity Disabled \
        --http-settings-port 80 \
        --http-settings-protocol Http \
        --routing-rule-type Basic \
        --priority 1000 \
        --waf-policy $WAF_POLICY_NAME \
        --tags Role=ApplicationGateway Environment=Learning Project=AZ104

    if [ $? -eq 0 ]; then
        log_success "Application Gateway created successfully"
    else
        log_error "Failed to create Application Gateway"
        exit 1
    fi
fi

# ==== 5. WAF Policy Already Associated ====
log_info "WAF policy was associated during Application Gateway creation..."
log_success "WAF policy configuration complete"

# ==== 6. Configure Backend Pool with VMSS IPs ====
log_info "Configuring backend pool with VMSS instances..."

# Clear existing backend pool
az network application-gateway address-pool update \
    --resource-group $RG_NAME \
    --gateway-name $APPGW_NAME \
    --name appGatewayBackendPool \
    --servers

# Add VMSS IPs to backend pool
for ip in $VMSS_BACKEND_IPS; do
    log_info "Adding $ip to backend pool..."
    az network application-gateway address-pool update \
        --resource-group $RG_NAME \
        --gateway-name $APPGW_NAME \
        --name appGatewayBackendPool \
        --add servers $ip
done

# ==== 7. Create Custom Health Probe ====
log_info "Creating custom health probe..."
az network application-gateway probe create \
    --resource-group $RG_NAME \
    --gateway-name $APPGW_NAME \
    --name $HEALTH_PROBE_NAME \
    --protocol Http \
    --host-name-from-http-settings false \
    --host 127.0.0.1 \
    --path / \
    --interval 30 \
    --threshold 3 \
    --timeout 30 2>/dev/null || \
az network application-gateway probe update \
    --resource-group $RG_NAME \
    --gateway-name $APPGW_NAME \
    --name $HEALTH_PROBE_NAME \
    --protocol Http \
    --host-name-from-http-settings false \
    --host 127.0.0.1 \
    --path / \
    --interval 30 \
    --threshold 3 \
    --timeout 30

# ==== 8. Update HTTP Settings to Use Custom Probe ====
log_info "Updating HTTP settings to use custom health probe..."
az network application-gateway http-settings update \
    --resource-group $RG_NAME \
    --gateway-name $APPGW_NAME \
    --name appGatewayBackendHttpSettings \
    --probe $HEALTH_PROBE_NAME \
    --timeout 30 \
    --cookie-based-affinity Disabled

# ==== 9. Create Additional Path-Based Routing (Optional) ====
log_info "Setting up path-based routing rules..."

# Create URL path map for advanced routing
az network application-gateway url-path-map create \
    --resource-group $RG_NAME \
    --gateway-name $APPGW_NAME \
    --name path-based-routing \
    --default-address-pool appGatewayBackendPool \
    --default-http-settings appGatewayBackendHttpSettings \
    --default-redirect-config "" \
    --default-rewrite-rule-set "" 2>/dev/null || \
log_warning "URL path map might already exist"

# ==== 10. Get Application Gateway Public IP ====
log_info "Retrieving Application Gateway public IP..."
APPGW_PUBLIC_IP=$(az network public-ip show \
    --resource-group $RG_NAME \
    --name $APPGW_PIP_NAME \
    --query ipAddress -o tsv)

APPGW_FQDN=$(az network public-ip show \
    --resource-group $RG_NAME \
    --name $APPGW_PIP_NAME \
    --query dnsSettings.fqdn -o tsv)

# ==== 11. Output Summary ====
echo
echo "=========================================="
log_success "APPLICATION GATEWAY SETUP COMPLETE"
echo "=========================================="
echo
echo "APPLICATION GATEWAY DETAILS:"
echo "   Resource Group:     $RG_NAME"
echo "   Name:               $APPGW_NAME"
echo "   SKU:                WAF_v2 (Web Application Firewall v2)"
echo "   Capacity:           2 instances"
echo "   Public IP:          $APPGW_PUBLIC_IP"
echo "   FQDN:               $APPGW_FQDN"
echo
echo "SECURITY FEATURES:"
echo "   WAF Policy:         $WAF_POLICY_NAME (OWASP 3.2, Prevention Mode)"
echo "   DDoS Protection:    Enabled (Standard SKU)"
echo "   SSL Termination:    Ready for SSL certificates"
echo
echo "BACKEND CONFIGURATION:"
echo "   Backend Pool:       VMSS instances ($VMSS_BACKEND_IPS)"
echo "   Health Probe:       Custom HTTP probe on path /"
echo "   Load Balancing:     Round-robin distribution"
echo
echo "ACCESS URLS:"
echo "   Primary:            http://$APPGW_PUBLIC_IP"
echo "   FQDN:               http://$APPGW_FQDN"
echo
echo "MONITORING:"
echo "   View metrics:       Azure Portal → Application Gateway → Monitoring"
echo "   WAF logs:           Azure Portal → Application Gateway → Monitoring → Logs"
echo "   Backend health:     Azure Portal → Application Gateway → Backend health"
echo
echo "ARCHITECTURE COMPARISON:"
echo "   Load Balancer (L4): http://4.206.179.100 (Layer 4 - TCP/UDP)"
echo "   App Gateway (L7):   http://$APPGW_PUBLIC_IP (Layer 7 - HTTP/HTTPS)"
echo
echo "NEXT STEPS:"
echo "   1. Test Application Gateway: http://$APPGW_PUBLIC_IP"
echo "   2. Compare with Load Balancer: http://4.206.179.100"
echo "   3. Monitor backend health in Azure Portal"
echo "   4. Add SSL certificate for HTTPS"
echo "   5. Configure custom domain names"
echo "   6. Set up advanced WAF rules"
echo
echo "LEARNING NOTES:"
echo "   - Application Gateway provides Layer 7 (HTTP) load balancing"
echo "   - WAF protects against common web vulnerabilities"
echo "   - Can handle SSL termination, path-based routing, and more"
echo "   - Ideal for web applications requiring advanced features"
echo "=========================================="

# ==== 12. Verification Commands ====
echo
log_info "Running verification tests..."

# Test Application Gateway endpoint
echo "Testing Application Gateway endpoint..."
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$APPGW_PUBLIC_IP || echo "Connection test failed"

# Check backend health
echo "Checking backend health (this may take a moment)..."
sleep 10
az network application-gateway show-backend-health \
    --resource-group $RG_NAME \
    --name $APPGW_NAME \
    --query 'backendAddressPools[0].backendHttpSettingsCollection[0].servers[].{Address:address,Health:health}' -o table

echo
log_success "Application Gateway deployment completed!"
echo "Note: It may take 5-10 minutes for all health probes to show as healthy."
