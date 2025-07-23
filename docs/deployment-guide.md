# Deployment Guide - Azure Multi-VNet Architecture

## 📋 Prerequisites

### Required Tools
- Azure CLI (version 2.50+)
- Bicep CLI (latest version)
- SSH key pair for VM authentication
- Your current public IP address

### Azure Subscription Requirements
- **Subscription**: Active Azure subscription
- **Permissions**: Contributor or Owner role
- **Quotas**: Ensure sufficient quotas for:
  - Virtual Machines: 15+ cores
  - Public IP addresses: 3
  - Load balancers: 2

## 🚀 Deployment Steps

### Step 1: Prepare Parameters

Create a `main.bicepparam` file:

```bicep
using './main.bicep'

// Required Parameters
param adminUsername = 'azuser'
param sshPublicKey = 'ssh-rsa AAAAB3NzaC1yc2EAAAA...' // Your SSH public key
param yourPublicIP = '203.0.113.1' // Your current public IP

// Optional Parameters
param location = 'canadacentral'
param environment = 'Learning'
param project = 'AZ104'
```

### Step 2: Get Your SSH Public Key

If you don't have an SSH key pair:

```bash
# Generate new SSH key pair
ssh-keygen -t rsa -b 4096 -f ~/.ssh/az104-key -N ""

# Get your public key
cat ~/.ssh/az104-key.pub
```

### Step 3: Get Your Public IP

```bash
# Get your current public IP
curl -s ifconfig.me
# or
curl -s ipinfo.io/ip
```

### Step 4: Deploy the Infrastructure

```bash
# Login to Azure
az login

# Set subscription (if needed)
az account set --subscription "your-subscription-id"

# Create resource group
az group create --name "az104-learn-dns-rg1" --location "canadacentral"

# Deploy the Bicep template
az deployment group create \
  --resource-group "az104-learn-dns-rg1" \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --verbose
```

### Alternative: Deploy with Inline Parameters

```bash
az deployment group create \
  --resource-group "az104-learn-dns-rg1" \
  --template-file main.bicep \
  --parameters \
    adminUsername="azuser" \
    sshPublicKey="ssh-rsa AAAAB3NzaC1yc2EAAAA..." \
    yourPublicIP="203.0.113.1" \
    location="canadacentral" \
  --verbose
```

## 📊 Post-Deployment Validation

### Step 1: Check Deployment Outputs

```bash
# Get deployment outputs
az deployment group show \
  --resource-group "az104-learn-dns-rg1" \
  --name "main" \
  --query properties.outputs
```

### Step 2: Test SSH Access

```bash
# SSH to jump box (replace with actual IP from outputs)
ssh -i ~/.ssh/az104-key azuser@<JUMPBOX_PUBLIC_IP>
```

### Step 3: Test DNS Resolution

From the jump box:

```bash
# Test DNS resolution
nslookup jumpbox.az104lab.internal
nslookup api.az104lab.internal
nslookup backend-vm.az104lab.internal
nslookup database-vm.az104lab.internal
```

### Step 4: Test Web Applications

```bash
# Test load balancer
curl http://<LOAD_BALANCER_PUBLIC_IP>

# Test application gateway
curl http://<APPLICATION_GATEWAY_PUBLIC_IP>

# Test cross-VNet connectivity (from jump box)
curl http://backend-vm.az104lab.internal
curl http://database-vm.az104lab.internal
```

### Step 5: Test Auto-scaling

Generate CPU load to trigger scaling:

```bash
# SSH to jump box first
ssh -i ~/.ssh/az104-key azuser@<JUMPBOX_PUBLIC_IP>

# From jump box, SSH to backend VM
ssh azuser@backend-vm.az104lab.internal

# Generate CPU load
stress-ng --cpu 4 --timeout 900s &

# Monitor scaling (from local machine)
watch -n 30 'az vmss list-instances --resource-group az104-learn-dns-rg1 --name web-vmss --query "length(@)"'
```

## 🎯 Key Testing Scenarios

### 1. Network Connectivity Matrix

| Source | Destination | Expected Result | Test Command |
|--------|-------------|----------------|--------------|
| Internet | Load Balancer | ✅ HTTP 200 | `curl http://<LB_IP>` |
| Internet | Application Gateway | ✅ HTTP 200 | `curl http://<AGW_IP>` |
| Jump Box | Backend VM | ✅ SSH + HTTP | `ssh azuser@backend-vm.az104lab.internal` |
| Jump Box | Database VM | ✅ SSH + HTTP | `ssh azuser@database-vm.az104lab.internal` |
| Backend VM | Database VM | ✅ All protocols | `ping database-vm.az104lab.internal` |

### 2. DNS Resolution Tests

```bash
# From any VM in VNet1 or VNet2
nslookup jumpbox.az104lab.internal      # Should resolve to private IP
nslookup api.az104lab.internal          # Should resolve to AGW public IP
nslookup backend.az104lab.internal      # Should CNAME to appgateway
nslookup db.az104lab.internal           # Should CNAME to database
```

### 3. Security Validation

```bash
# SSH should only work from your IP to jump box
ssh azuser@<JUMPBOX_PUBLIC_IP>          # Should work from your IP
ssh azuser@<BACKEND_VM_PRIVATE_IP>      # Should fail from internet

# Web access should work from anywhere
curl http://<LOAD_BALANCER_IP>          # Should work from anywhere
curl http://<APPLICATION_GATEWAY_IP>    # Should work from anywhere
```

## 🛠️ Customization Options

### Scaling Configuration

Modify auto-scaling thresholds in the Bicep template:

```bicep
// In the vmssAutoscale resource
threshold: 70  // Change from 80 to 70 for more aggressive scaling
```

### VM Sizes

Change VM SKUs for different performance levels:

```bicep
vmSize: 'Standard_B2s'  // Upgrade from Standard_B1s
```

### Additional Subnets

Add more subnets to VNet2 for microservices:

```bicep
{
  name: 'microservices-subnet'
  properties: {
    addressPrefix: '10.1.3.0/24'
    networkSecurityGroup: {
      id: vnet2Nsg.id
    }
  }
}
