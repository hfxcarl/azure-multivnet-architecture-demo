#!/bin/bash

# ==== CONFIGURATION ====
RG_NAME="az104-learn-dns-rg1"
LOCATION="canadacentral"
VNET_NAME="vnet1"
SUBNET_NAME="subnet1"
VMSS_NAME="web-vmss"
NSG_NAME="web-vmss-nsg"
LB_NAME="web-vmss-lb"
USERNAME="azuser"
SSH_KEY_NAME="az104-learn-dns-secure-jumpbox-key"
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}"

# Auto-scaling settings
INITIAL_CAPACITY=1
MIN_CAPACITY=1
MAX_CAPACITY=10
SCALE_OUT_CPU_THRESHOLD=80
SCALE_IN_CPU_THRESHOLD=20
DURATION_MINUTES=10

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
log_info "Starting VMSS Web Servers setup script..."

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

# Check if VNet and subnet exist
if ! az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET_NAME --name $SUBNET_NAME &> /dev/null; then
    log_error "Subnet '$SUBNET_NAME' does not exist in VNet '$VNET_NAME'"
    exit 1
fi

# Check if SSH key exists
if [ ! -f "$SSH_KEY_PATH.pub" ]; then
    log_error "SSH public key not found at $SSH_KEY_PATH.pub. Please run the jumpbox script first."
    exit 1
fi

log_success "All prerequisites validated"

# ==== 1. Create Network Security Group for VMSS ====
log_info "Creating Network Security Group for VMSS..."
if az network nsg show --resource-group $RG_NAME --name $NSG_NAME &> /dev/null; then
    log_warning "NSG '$NSG_NAME' already exists, skipping creation"
else
    az network nsg create \
        --resource-group $RG_NAME \
        --name $NSG_NAME \
        --location $LOCATION \
        --tags Role=WebServer Environment=Learning Project=AZ104
    log_success "Network Security Group created"
fi

# ==== 2. Configure NSG Rules for Web Traffic ====
log_info "Configuring NSG rules..."

# Allow HTTP traffic
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowHTTP \
    --protocol Tcp \
    --direction Inbound \
    --priority 1000 \
    --source-address-prefixes "*" \
    --destination-port-ranges 80 \
    --access Allow \
    --description "Allow HTTP traffic" 2>/dev/null || \
az network nsg rule update \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowHTTP \
    --description "Allow HTTP traffic"

# Allow HTTPS traffic
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowHTTPS \
    --protocol Tcp \
    --direction Inbound \
    --priority 1010 \
    --source-address-prefixes "*" \
    --destination-port-ranges 443 \
    --access Allow \
    --description "Allow HTTPS traffic" 2>/dev/null || \
az network nsg rule update \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowHTTPS \
    --description "Allow HTTPS traffic"

# Allow SSH from VNet (for jump box access)
VNET_ADDRESS_SPACE=$(az network vnet show \
    --resource-group $RG_NAME \
    --name $VNET_NAME \
    --query 'addressSpace.addressPrefixes[0]' -o tsv)

az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowSSHFromVNet \
    --protocol Tcp \
    --direction Inbound \
    --priority 2000 \
    --source-address-prefixes "$VNET_ADDRESS_SPACE" \
    --destination-port-ranges 22 \
    --access Allow \
    --description "Allow SSH from VNet (jump box access)" 2>/dev/null || \
az network nsg rule update \
    --resource-group $RG_NAME \
    --nsg-name $NSG_NAME \
    --name AllowSSHFromVNet \
    --source-address-prefixes "$VNET_ADDRESS_SPACE" \
    --description "Allow SSH from VNet (jump box access)"

log_success "NSG rules configured"

# ==== 3. Create Load Balancer ====
log_info "Creating Load Balancer..."
if az network lb show --resource-group $RG_NAME --name $LB_NAME &> /dev/null; then
    log_warning "Load Balancer '$LB_NAME' already exists, skipping creation"
else
    # Create public IP for load balancer
    az network public-ip create \
        --resource-group $RG_NAME \
        --name "${LB_NAME}-pip" \
        --sku Standard \
        --allocation-method Static \
        --location $LOCATION

    # Create load balancer
    az network lb create \
        --resource-group $RG_NAME \
        --name $LB_NAME \
        --sku Standard \
        --public-ip-address "${LB_NAME}-pip" \
        --frontend-ip-name "${LB_NAME}-frontend" \
        --backend-pool-name "${LB_NAME}-backend"

    # Create health probe
    az network lb probe create \
        --resource-group $RG_NAME \
        --lb-name $LB_NAME \
        --name http-probe \
        --protocol Http \
        --port 80 \
        --path /

    # Create load balancing rule
    az network lb rule create \
        --resource-group $RG_NAME \
        --lb-name $LB_NAME \
        --name http-rule \
        --protocol Tcp \
        --frontend-port 80 \
        --backend-port 80 \
        --frontend-ip-name "${LB_NAME}-frontend" \
        --backend-pool-name "${LB_NAME}-backend" \
        --probe-name http-probe

    log_success "Load Balancer created"
fi

# ==== 4. Create Cloud-Init Script for Web Server Setup ====
log_info "Creating cloud-init script for web servers..."

cat > /tmp/web-server-init.yml << 'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - nginx
  - htop
  - curl
  - stress-ng

write_files:
  - path: /var/www/html/index.html
    content: |
      <!DOCTYPE html>
      <html>
      <head>
          <title>AZ-104 Web Server</title>
          <style>
              body { font-family: Arial, sans-serif; margin: 40px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; }
              .container { background: rgba(255,255,255,0.1); padding: 30px; border-radius: 10px; backdrop-filter: blur(10px); }
              .server-info { background: rgba(0,0,0,0.3); padding: 20px; border-radius: 5px; margin: 20px 0; }
              .highlight { color: #ffd700; font-weight: bold; }
          </style>
      </head>
      <body>
          <div class="container">
              <h1>AZ-104 Learning Lab - Web Server</h1>
              <div class="server-info">
                  <h3>Server Information:</h3>
                  <p><span class="highlight">Hostname:</span> <span id="hostname">Loading...</span></p>
                  <p><span class="highlight">IP Address:</span> <span id="ip">Loading...</span></p>
                  <p><span class="highlight">Load Time:</span> <span id="loadtime"></span></p>
                  <p><span class="highlight">Instance:</span> Part of VMSS with auto-scaling</p>
              </div>
              <h3>Lab Architecture:</h3>
              <ul>
                  <li>DONE: Jump Box (Management Access)</li>
                  <li>DONE: VMSS Web Servers (Auto-scaling)</li>
                  <li>NEXT: Application Gateway (Coming Next)</li>
              </ul>
              <div style="margin-top: 30px; padding: 15px; background: rgba(255,255,255,0.1); border-radius: 5px;">
                  <p><strong>Test Auto-scaling:</strong></p>
                  <button onclick="stressTest()" style="padding: 10px 20px; background: #ff6b6b; color: white; border: none; border-radius: 5px; cursor: pointer;">Generate CPU Load</button>
                  <p id="stress-status"></p>
              </div>
          </div>
          <script>
              // Display server info
              document.getElementById('hostname').textContent = window.location.hostname;
              fetch('/api/info').then(r => r.json()).then(d => {
                  document.getElementById('ip').textContent = d.ip;
              }).catch(() => {
                  document.getElementById('ip').textContent = 'Private IP';
              });
              document.getElementById('loadtime').textContent = new Date().toLocaleString();
              
              // Stress test function
              function stressTest() {
                  document.getElementById('stress-status').textContent = 'Generating CPU load for 2 minutes...';
                  fetch('/api/stress', {method: 'POST'});
                  setTimeout(() => {
                      document.getElementById('stress-status').textContent = 'Stress test completed. Check Azure Monitor for auto-scaling!';
                  }, 120000);
              }
          </script>
      </body>
      </html>

  - path: /etc/nginx/sites-available/api
    content: |
      server {
          listen 8080;
          location /api/info {
              add_header Content-Type application/json;
              return 200 '{"ip":"'$server_addr'","hostname":"'$hostname'"}';
          }
          location /api/stress {
              add_header Content-Type application/json;
              if ($request_method = POST) {
                  access_by_lua_block {
                      os.execute("stress-ng --cpu 4 --timeout 120s &")
                  }
                  return 200 '{"status":"stress test started"}';
              }
          }
      }

runcmd:
  - systemctl start nginx
  - systemctl enable nginx
  - ln -sf /etc/nginx/sites-available/api /etc/nginx/sites-enabled/
  - nginx -t && systemctl reload nginx
  - ufw allow 'Nginx Full'
  - ufw allow ssh
  - echo "Web server setup completed at $(date)" >> /var/log/setup.log

EOF

log_success "Cloud-init script created"

# ==== 5. Create VMSS ====
log_info "Creating Virtual Machine Scale Set..."

if az vmss show --resource-group $RG_NAME --name $VMSS_NAME &> /dev/null; then
    log_warning "VMSS '$VMSS_NAME' already exists. Skipping VMSS creation."
    SKIP_VMSS=true
else
    SKIP_VMSS=false
fi

if [ "$SKIP_VMSS" = false ]; then
    # Get subnet ID
    SUBNET_ID=$(az network vnet subnet show \
        --resource-group $RG_NAME \
        --vnet-name $VNET_NAME \
        --name $SUBNET_NAME \
        --query id -o tsv)

    # Create VMSS
    az vmss create \
        --resource-group $RG_NAME \
        --name $VMSS_NAME \
        --image Ubuntu2204 \
        --vm-sku Standard_B1s \
        --instance-count $INITIAL_CAPACITY \
        --admin-username $USERNAME \
        --ssh-key-values "$SSH_KEY_PATH.pub" \
        --subnet $SUBNET_ID \
        --nsg $NSG_NAME \
        --lb $LB_NAME \
        --backend-pool-name "${LB_NAME}-backend" \
        --upgrade-policy-mode Automatic \
        --custom-data /tmp/web-server-init.yml \
        --tags Role=WebServer Environment=Learning Project=AZ104 Owner=$USERNAME

    if [ $? -eq 0 ]; then
        log_success "VMSS created successfully"
    else
        log_error "Failed to create VMSS"
        exit 1
    fi
fi

# ==== 6. Configure Auto-scaling Rules ====
log_info "Configuring auto-scaling rules..."

# Scale out rule (CPU > 80% for 10 minutes)
az monitor autoscale create \
    --resource-group $RG_NAME \
    --resource $VMSS_NAME \
    --resource-type Microsoft.Compute/virtualMachineScaleSets \
    --name "${VMSS_NAME}-autoscale" \
    --min-count $MIN_CAPACITY \
    --max-count $MAX_CAPACITY \
    --count $INITIAL_CAPACITY \
    --tags Environment=Learning Project=AZ104

# Scale out rule
az monitor autoscale rule create \
    --resource-group $RG_NAME \
    --autoscale-name "${VMSS_NAME}-autoscale" \
    --condition "Percentage CPU > $SCALE_OUT_CPU_THRESHOLD avg ${DURATION_MINUTES}m" \
    --scale out 1

# Scale in rule
az monitor autoscale rule create \
    --resource-group $RG_NAME \
    --autoscale-name "${VMSS_NAME}-autoscale" \
    --condition "Percentage CPU < $SCALE_IN_CPU_THRESHOLD avg ${DURATION_MINUTES}m" \
    --scale in 1

log_success "Auto-scaling rules configured"

# ==== 7. Get Load Balancer Public IP ====
log_info "Retrieving load balancer public IP..."
LB_PUBLIC_IP=$(az network public-ip show \
    --resource-group $RG_NAME \
    --name "${LB_NAME}-pip" \
    --query ipAddress -o tsv)

# ==== 8. Output Summary ====
echo
echo "=========================================="
log_success "VMSS WEB SERVERS SETUP COMPLETE"
echo "=========================================="
echo
echo "VMSS DETAILS:"
echo "   Resource Group:    $RG_NAME"
echo "   VMSS Name:         $VMSS_NAME"
echo "   Load Balancer:     $LB_NAME"
echo "   Public IP:         $LB_PUBLIC_IP"
echo "   Initial Instances: $INITIAL_CAPACITY"
echo "   Min Instances:     $MIN_CAPACITY"
echo "   Max Instances:     $MAX_CAPACITY"
echo
echo "AUTO-SCALING RULES:"
echo "   Scale Out:  CPU > ${SCALE_OUT_CPU_THRESHOLD}% for ${DURATION_MINUTES} minutes → +1 instance"
echo "   Scale In:   CPU < ${SCALE_IN_CPU_THRESHOLD}% for ${DURATION_MINUTES} minutes → -1 instance"
echo
echo "WEB ACCESS:"
echo "   Public URL: http://$LB_PUBLIC_IP"
echo "   Test the web server and auto-scaling functionality!"
echo
echo "SSH ACCESS (from jump box):"
echo "   First, SSH to your jump box, then:"
echo "   az vmss list-instance-connection-info --resource-group $RG_NAME --name $VMSS_NAME"
echo
echo "MONITORING:"
echo "   View auto-scaling: Azure Portal → Monitor → Autoscale"
echo "   View metrics: Azure Portal → VMSS → Monitoring → Metrics"
echo
echo "NEXT STEPS:"
echo "   1. Test the web application: http://$LB_PUBLIC_IP"
echo "   2. Monitor auto-scaling in Azure Portal"
echo "   3. Create Application Gateway for advanced load balancing"
echo "   4. Configure custom domains and SSL certificates"
echo "=========================================="

# Clean up temporary files
rm -f /tmp/web-server-init.yml
