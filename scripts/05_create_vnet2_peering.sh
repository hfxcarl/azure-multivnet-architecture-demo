#!/bin/bash

# ==== CONFIGURATION ====
RG_NAME="az104-learn-dns-rg1"
LOCATION="canadacentral"

# Existing VNet1 Configuration
VNET1_NAME="vnet1"
DNS_ZONE_NAME="az104lab.internal"

# New VNet2 Configuration  
VNET2_NAME="vnet2"
VNET2_ADDRESS_SPACE="10.1.0.0/16"
VNET2_SUBNET1_NAME="backend-subnet"
VNET2_SUBNET1_PREFIX="10.1.1.0/24"
VNET2_SUBNET2_NAME="database-subnet"
VNET2_SUBNET2_PREFIX="10.1.2.0/24"

# VM Configuration for VNet2
BACKEND_VM_NAME="backend-vm"
DATABASE_VM_NAME="database-vm"
MONITORING_VM_NAME="monitoring-vm"
NSG_VNET2_NAME="vnet2-nsg"
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
log_info "Starting VNet2 Peering and DNS Extension setup..."

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

# Check if VNet1 exists
if ! az network vnet show --resource-group $RG_NAME --name $VNET1_NAME &> /dev/null; then
    log_error "VNet1 '$VNET1_NAME' does not exist. Please run the previous scripts first."
    exit 1
fi

# Check if Private DNS zone exists
if ! az network private-dns zone show --resource-group $RG_NAME --name $DNS_ZONE_NAME &> /dev/null; then
    log_error "Private DNS zone '$DNS_ZONE_NAME' does not exist. Please run the DNS setup script first."
    exit 1
fi

# Check if SSH key exists
if [ ! -f "$SSH_KEY_PATH.pub" ]; then
    log_error "SSH public key not found at $SSH_KEY_PATH.pub"
    exit 1
fi

log_success "All prerequisites validated"

# ==== 1. Create VNet2 ====
log_info "Creating VNet2: $VNET2_NAME"
if az network vnet show --resource-group $RG_NAME --name $VNET2_NAME &> /dev/null; then
    log_warning "VNet2 '$VNET2_NAME' already exists, skipping creation"
else
    az network vnet create \
        --resource-group $RG_NAME \
        --name $VNET2_NAME \
        --address-prefixes $VNET2_ADDRESS_SPACE \
        --location $LOCATION \
        --tags Environment=Learning Project=AZ104 Purpose=VNetPeering
    log_success "VNet2 created"
fi

# ==== 2. Create Subnets in VNet2 ====
log_info "Creating subnets in VNet2..."

# Backend subnet
if az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET2_NAME --name $VNET2_SUBNET1_NAME &> /dev/null; then
    log_warning "Subnet '$VNET2_SUBNET1_NAME' already exists"
else
    az network vnet subnet create \
        --resource-group $RG_NAME \
        --vnet-name $VNET2_NAME \
        --name $VNET2_SUBNET1_NAME \
        --address-prefixes $VNET2_SUBNET1_PREFIX
    log_success "Backend subnet created"
fi

# Database subnet
if az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET2_NAME --name $VNET2_SUBNET2_NAME &> /dev/null; then
    log_warning "Subnet '$VNET2_SUBNET2_NAME' already exists"
else
    az network vnet subnet create \
        --resource-group $RG_NAME \
        --vnet-name $VNET2_NAME \
        --name $VNET2_SUBNET2_NAME \
        --address-prefixes $VNET2_SUBNET2_PREFIX
    log_success "Database subnet created"
fi

# ==== 3. Create Network Security Group for VNet2 ====
log_info "Creating NSG for VNet2..."
if az network nsg show --resource-group $RG_NAME --name $NSG_VNET2_NAME &> /dev/null; then
    log_warning "NSG '$NSG_VNET2_NAME' already exists"
else
    az network nsg create \
        --resource-group $RG_NAME \
        --name $NSG_VNET2_NAME \
        --location $LOCATION \
        --tags Environment=Learning Project=AZ104
    log_success "NSG created"
fi

# ==== 4. Configure NSG Rules for VNet2 ====
log_info "Configuring NSG rules for VNet2..."

# Allow SSH from VNet1 (Jump Box access)
VNET1_ADDRESS_SPACE=$(az network vnet show --resource-group $RG_NAME --name $VNET1_NAME --query 'addressSpace.addressPrefixes[0]' -o tsv)

az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_VNET2_NAME \
    --name AllowSSHFromVNet1 \
    --protocol Tcp \
    --direction Inbound \
    --priority 1000 \
    --source-address-prefixes "$VNET1_ADDRESS_SPACE" \
    --destination-port-ranges 22 \
    --access Allow \
    --description "Allow SSH from VNet1 (Jump Box)" 2>/dev/null || \
az network nsg rule update \
    --resource-group $RG_NAME \
    --nsg-name $NSG_VNET2_NAME \
    --name AllowSSHFromVNet1 \
    --source-address-prefixes "$VNET1_ADDRESS_SPACE"

# Allow HTTP/HTTPS for backend services
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_VNET2_NAME \
    --name AllowHTTPFromVNets \
    --protocol Tcp \
    --direction Inbound \
    --priority 1010 \
    --source-address-prefixes "VirtualNetwork" \
    --destination-port-ranges 80 443 \
    --access Allow \
    --description "Allow HTTP/HTTPS from VNets" 2>/dev/null || true

# Allow database connections (MySQL/PostgreSQL) from VNet2 only
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_VNET2_NAME \
    --name AllowDatabaseFromVNet2 \
    --protocol Tcp \
    --direction Inbound \
    --priority 1020 \
    --source-address-prefixes "$VNET2_ADDRESS_SPACE" \
    --destination-port-ranges 3306 5432 \
    --access Allow \
    --description "Allow database connections from VNet2" 2>/dev/null || true

log_success "NSG rules configured"

# ==== 5. Create VMs in VNet2 ====
log_info "Creating VMs in VNet2..."

# Cloud-init script for backend services
cat > /tmp/backend-init.yml << 'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - nginx
  - nodejs
  - npm
  - htop
  - curl

write_files:
  - path: /var/www/html/index.html
    content: |
      <!DOCTYPE html>
      <html>
      <head>
          <title>Backend API Server</title>
          <style>
              body { font-family: Arial, sans-serif; margin: 40px; background: linear-gradient(135deg, #74b9ff 0%, #0984e3 100%); color: white; }
              .container { background: rgba(255,255,255,0.1); padding: 30px; border-radius: 10px; }
              .api-info { background: rgba(0,0,0,0.3); padding: 20px; border-radius: 5px; margin: 20px 0; }
          </style>
      </head>
      <body>
          <div class="container">
              <h1>Backend API Server</h1>
              <div class="api-info">
                  <h3>Server Information:</h3>
                  <p><strong>Hostname:</strong> <span id="hostname">Loading...</span></p>
                  <p><strong>IP Address:</strong> <span id="ip">Loading...</span></p>
                  <p><strong>VNet:</strong> VNet2 (Backend Tier)</p>
                  <p><strong>Purpose:</strong> Backend API Services</p>
              </div>
              <h3>API Endpoints:</h3>
              <ul>
                  <li>GET /api/health - Health check</li>
                  <li>GET /api/data - Sample data</li>
                  <li>GET /api/database - Database connection test</li>
              </ul>
          </div>
          <script>
              document.getElementById('hostname').textContent = window.location.hostname;
              document.getElementById('ip').textContent = window.location.host;
          </script>
      </body>
      </html>

runcmd:
  - systemctl start nginx
  - systemctl enable nginx
  - ufw allow 'Nginx Full'
  - ufw allow ssh
  - echo "Backend server setup completed at $(date)" >> /var/log/setup.log

EOF

# Cloud-init script for database server
cat > /tmp/database-init.yml << 'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - mysql-server
  - nginx
  - htop
  - curl

write_files:
  - path: /var/www/html/index.html
    content: |
      <!DOCTYPE html>
      <html>
      <head>
          <title>Database Server</title>
          <style>
              body { font-family: Arial, sans-serif; margin: 40px; background: linear-gradient(135deg, #fd79a8 0%, #e84393 100%); color: white; }
              .container { background: rgba(255,255,255,0.1); padding: 30px; border-radius: 10px; }
              .db-info { background: rgba(0,0,0,0.3); padding: 20px; border-radius: 5px; margin: 20px 0; }
          </style>
      </head>
      <body>
          <div class="container">
              <h1>Database Server</h1>
              <div class="db-info">
                  <h3>Server Information:</h3>
                  <p><strong>Hostname:</strong> <span id="hostname">Loading...</span></p>
                  <p><strong>IP Address:</strong> <span id="ip">Loading...</span></p>
                  <p><strong>VNet:</strong> VNet2 (Database Tier)</p>
                  <p><strong>Database:</strong> MySQL Server</p>
              </div>
              <h3>Database Services:</h3>
              <ul>
                  <li>MySQL Server (Port 3306)</li>
                  <li>Backup Services</li>
                  <li>Performance Monitoring</li>
              </ul>
          </div>
          <script>
              document.getElementById('hostname').textContent = window.location.hostname;
              document.getElementById('ip').textContent = window.location.host;
          </script>
      </body>
      </html>

runcmd:
  - systemctl start nginx
  - systemctl enable nginx
  - systemctl start mysql
  - systemctl enable mysql
  - mysql -e "CREATE DATABASE testdb;"
  - echo "Database server setup completed at $(date)" >> /var/log/setup.log

EOF

# Create Backend VM
if az vm show --resource-group $RG_NAME --name $BACKEND_VM_NAME &> /dev/null; then
    log_warning "Backend VM already exists"
else
    BACKEND_SUBNET_ID=$(az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET2_NAME --name $VNET2_SUBNET1_NAME --query id -o tsv)
    
    az vm create \
        --resource-group $RG_NAME \
        --name $BACKEND_VM_NAME \
        --image Ubuntu2204 \
        --size Standard_B1s \
        --admin-username $USERNAME \
        --ssh-key-values "$SSH_KEY_PATH.pub" \
        --subnet $BACKEND_SUBNET_ID \
        --nsg $NSG_VNET2_NAME \
        --public-ip-address "" \
        --custom-data /tmp/backend-init.yml \
        --tags Role=Backend Environment=Learning Project=AZ104 Tier=Backend

    log_success "Backend VM created"
fi

# Create Database VM
if az vm show --resource-group $RG_NAME --name $DATABASE_VM_NAME &> /dev/null; then
    log_warning "Database VM already exists"
else
    DATABASE_SUBNET_ID=$(az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET2_NAME --name $VNET2_SUBNET2_NAME --query id -o tsv)
    
    az vm create \
        --resource-group $RG_NAME \
        --name $DATABASE_VM_NAME \
        --image Ubuntu2204 \
        --size Standard_B1s \
        --admin-username $USERNAME \
        --ssh-key-values "$SSH_KEY_PATH.pub" \
        --subnet $DATABASE_SUBNET_ID \
        --nsg $NSG_VNET2_NAME \
        --public-ip-address "" \
        --custom-data /tmp/database-init.yml \
        --tags Role=Database Environment=Learning Project=AZ104 Tier=Database

    log_success "Database VM created"
fi

# ==== 6. Create VNet Peering ====
log_info "Creating VNet peering between VNet1 and VNet2..."

# Get VNet resource IDs
VNET1_ID=$(az network vnet show --resource-group $RG_NAME --name $VNET1_NAME --query id -o tsv)
VNET2_ID=$(az network vnet show --resource-group $RG_NAME --name $VNET2_NAME --query id -o tsv)

# Create peering from VNet1 to VNet2
PEERING1_NAME="vnet1-to-vnet2"
if az network vnet peering show --resource-group $RG_NAME --vnet-name $VNET1_NAME --name $PEERING1_NAME &> /dev/null; then
    log_warning "Peering VNet1→VNet2 already exists"
else
    az network vnet peering create \
        --resource-group $RG_NAME \
        --vnet-name $VNET1_NAME \
        --name $PEERING1_NAME \
        --remote-vnet $VNET2_ID \
        --allow-vnet-access true \
        --allow-forwarded-traffic true \
        --allow-gateway-transit false \
        --use-remote-gateways false
    log_success "Created peering: VNet1 → VNet2"
fi

# Create peering from VNet2 to VNet1
PEERING2_NAME="vnet2-to-vnet1"
if az network vnet peering show --resource-group $RG_NAME --vnet-name $VNET2_NAME --name $PEERING2_NAME &> /dev/null; then
    log_warning "Peering VNet2→VNet1 already exists"
else
    az network vnet peering create \
        --resource-group $RG_NAME \
        --vnet-name $VNET2_NAME \
        --name $PEERING2_NAME \
        --remote-vnet $VNET1_ID \
        --allow-vnet-access true \
        --allow-forwarded-traffic true \
        --allow-gateway-transit false \
        --use-remote-gateways false
    log_success "Created peering: VNet2 → VNet1"
fi

# ==== 7. Link VNet2 to Private DNS Zone ====
log_info "Linking VNet2 to Private DNS Zone..."
VNET2_LINK_NAME="vnet2-link"

if az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE_NAME --name $VNET2_LINK_NAME &> /dev/null; then
    log_warning "VNet2 DNS link already exists"
else
    az network private-dns link vnet create \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --name $VNET2_LINK_NAME \
        --virtual-network $VNET2_NAME \
        --registration-enabled true \
        --tags Environment=Learning Project=AZ104
    log_success "VNet2 linked to Private DNS Zone"
fi

# ==== 8. Create DNS Records for VNet2 VMs ====
log_info "Creating DNS records for VNet2 VMs..."

# Wait a moment for VMs to get IPs
sleep 30

# Get VM IP addresses
BACKEND_IP=$(az vm list-ip-addresses --resource-group $RG_NAME --name $BACKEND_VM_NAME \
    --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)
DATABASE_IP=$(az vm list-ip-addresses --resource-group $RG_NAME --name $DATABASE_VM_NAME \
    --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)

if [ -n "$BACKEND_IP" ] && [ "$BACKEND_IP" != "null" ]; then
    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name backend \
        --ipv4-address $BACKEND_IP 2>/dev/null || true
    log_success "Created DNS: backend.$DNS_ZONE_NAME → $BACKEND_IP"
fi

if [ -n "$DATABASE_IP" ] && [ "$DATABASE_IP" != "null" ]; then
    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $DNS_ZONE_NAME \
        --record-set-name database \
        --ipv4-address $DATABASE_IP 2>/dev/null || true
    log_success "Created DNS: database.$DNS_ZONE_NAME → $DATABASE_IP"
fi

# Create service aliases
az network private-dns record-set cname set-record \
    --resource-group $RG_NAME \
    --zone-name $DNS_ZONE_NAME \
    --record-set-name db \
    --cname database.$DNS_ZONE_NAME 2>/dev/null || true

az network private-dns record-set cname set-record \
    --resource-group $RG_NAME \
    --zone-name $DNS_ZONE_NAME \
    --record-set-name api-backend \
    --cname backend.$DNS_ZONE_NAME 2>/dev/null || true

# ==== 9. Verification and Testing ====
log_info "Running connectivity tests..."

# Create connectivity test script
cat > /tmp/vnet_connectivity_test.sh << 'EOF'
#!/bin/bash
echo "=== VNet Peering and DNS Connectivity Test ==="
echo "Testing from $(hostname) - $(hostname -I)"
echo

echo "1. DNS Resolution Test:"
for host in jumpbox web backend database db api-backend; do
    result=$(nslookup $host.az104lab.internal 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
    if [ -n "$result" ]; then
        echo "   ✓ $host.az104lab.internal → $result"
    else
        echo "   ✗ $host.az104lab.internal → Failed"
    fi
done

echo
echo "2. Cross-VNet Connectivity Test:"
# Test connectivity to VNet2 from VNet1
for host in backend database; do
    ip=$(nslookup $host.az104lab.internal 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
    if [ -n "$ip" ]; then
        if ping -c 2 -W 3 $ip >/dev/null 2>&1; then
            echo "   ✓ Ping to $host ($ip) - SUCCESS"
        else
            echo "   ✗ Ping to $host ($ip) - FAILED"
        fi
    fi
done

echo
echo "3. HTTP Service Test:"
for service in backend database; do
    if curl -s --max-time 5 http://$service.az104lab.internal >/dev/null 2>&1; then
        echo "   ✓ HTTP to $service.az104lab.internal - SUCCESS"
    else
        echo "   ✗ HTTP to $service.az104lab.internal - FAILED"
    fi
done

echo
echo "=== Test Complete ==="
EOF

chmod +x /tmp/vnet_connectivity_test.sh

# ==== 10. Output Summary ====
echo
echo "=========================================="
log_success "VNET PEERING & DNS EXTENSION COMPLETE"
echo "=========================================="
echo
echo "NETWORK ARCHITECTURE:"
echo "   VNet1 (vnet1):        10.0.0.0/16"
echo "   ├─ subnet1:           Web tier (VMSS)"
echo "   ├─ subnet2:           Jump box"
echo "   └─ eca-appgwsubnet:   Application Gateway"
echo "   "
echo "   VNet2 (vnet2):        10.1.0.0/16"
echo "   ├─ backend-subnet:    10.1.1.0/24 (Backend services)"
echo "   └─ database-subnet:   10.1.2.0/24 (Database tier)"
echo
echo "PEERING STATUS:"
echo "   VNet1 ↔ VNet2:        Bidirectional peering enabled"
echo "   Traffic forwarding:   Enabled"
echo "   Gateway transit:      Disabled"
echo
echo "VMs CREATED:"
if [ -n "$BACKEND_IP" ]; then
    echo "   backend-vm:           $BACKEND_IP (Backend tier)"
fi
if [ -n "$DATABASE_IP" ]; then
    echo "   database-vm:          $DATABASE_IP (Database tier)"  
fi
echo
echo "DNS RECORDS:"
echo "   Existing from VNet1:"
echo "   ├─ jumpbox.az104lab.internal"
echo "   ├─ web.az104lab.internal" 
echo "   ├─ api.az104lab.internal"
echo "   └─ appgateway.az104lab.internal"
echo "   "
echo "   New from VNet2:"
echo "   ├─ backend.az104lab.internal → $BACKEND_IP"
echo "   ├─ database.az104lab.internal → $DATABASE_IP"
echo "   ├─ db.az104lab.internal → database.az104lab.internal (CNAME)"
echo "   └─ api-backend.az104lab.internal → backend.az104lab.internal (CNAME)"
echo
echo "TESTING COMMANDS:"
echo "   SSH to jump box:"
echo "   ssh -i ~/.ssh/az104-learn-dns-secure-jumpbox-key azuser@jumpbox.az104lab.internal"
echo "   "
echo "   From jump box, SSH to VNet2 VMs:"
echo "   ssh azuser@backend.az104lab.internal"
echo "   ssh azuser@database.az104lab.internal"
echo "   "
echo "   Test web services:"
echo "   curl http://backend.az104lab.internal"
echo "   curl http://database.az104lab.internal"
echo "   "
echo "   Run connectivity test:"
echo "   scp /tmp/vnet_connectivity_test.sh azuser@jumpbox.az104lab.internal:~/"
echo "   ssh azuser@jumpbox.az104lab.internal './vnet_connectivity_test.sh'"
echo
echo "AZURE PORTAL VERIFICATION:"
echo "   VNets: Portal → Virtual networks → Peerings"
echo "   DNS: Portal → Private DNS zones → az104lab.internal"
echo "   VMs: Portal → Virtual machines"
echo
echo "AZ-104 EXAM TOPICS COVERED:"
echo "   ✓ VNet-to-VNet peering"
echo "   ✓ Cross-VNet communication"
echo "   ✓ Private DNS across VNets" 
echo "   ✓ Multi-tier architecture"
echo "   ✓ Network security groups"
echo "   ✓ Service discovery patterns"
echo "=========================================="

# Clean up temporary files
rm -f /tmp/backend-init.yml /tmp/database-init.yml /tmp/vnet_connectivity_test.sh
