// ===================================
// Parameters file for Azure Multi-VNet Architecture
// Usage: az deployment group create --template-file main.bicep --parameters main.bicepparam
// ===================================

using './main.bicep'

// ===================================
// REQUIRED PARAMETERS
// ===================================

@description('Admin username for all VMs')
param adminUsername = 'azuser'

@description('SSH public key for VM authentication - REPLACE WITH YOUR KEY')
param sshPublicKey = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC... your-ssh-public-key-here'

@description('Your current public IP address for jump box access - REPLACE WITH YOUR IP')
param yourPublicIP = '203.0.113.1'

// ===================================
// OPTIONAL PARAMETERS
// ===================================

@description('Azure region for all resources')
param location = 'canadacentral'

@description('Environment tag for resource organization')
param environment = 'Learning'

@description('Project tag for cost tracking')
param project = 'AZ104'

// ===================================
// EXAMPLE CONFIGURATIONS
// ===================================

/*
// Production Configuration Example
param environment = 'Production'
param project = 'WebApp-Prod'

// Development Configuration Example  
param environment = 'Development'
param project = 'WebApp-Dev'

// Different Region Example
param location = 'eastus'

// Different Admin User Example
param adminUsername = 'azureuser'
*/

// ===================================
// DEPLOYMENT VALIDATION
// ===================================

/*
Before deploying, verify:

1. SSH Public Key:
   - Generate: ssh-keygen -t rsa -b 4096 -f ~/.ssh/az104-key -N ""
   - Get key: cat ~/.ssh/az104-key.pub
   - Copy the entire key starting with 'ssh-rsa ...'

2. Current Public IP:
   - Get IP: curl -s ifconfig.me
   - Ensure it's your actual public IP address

3. Azure Subscription:
   - Login: az login
   - Set subscription: az account set --subscription "your-subscription-id"
   - Check quotas for VMs, Public IPs, Load Balancers

4. Resource Group:
   - Create: az group create --name "az104-learn-dns-rg1" --location "canadacentral"

Deployment Command:
az deployment group create \
  --resource-group "az104-learn-dns-rg1" \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --verbose
*/
