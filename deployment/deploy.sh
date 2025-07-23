#!/bin/bash
set -e

echo "🚀 Azure Multi-VNet Architecture Deployment"
echo "==========================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
RG_NAME="az104-learn-dns-rg1"
LOCATION="canadacentral"
TEMPLATE_FILE="main.bicep"
PARAMETERS_FILE="main.bicepparam"

# Prerequisites check
log_info "Checking prerequisites..."
if ! command -v az &> /dev/null; then
    log_error "Azure CLI is not installed"
    exit 1
fi

if ! az account show &> /dev/null; then
    log_error "Please login to Azure CLI first: az login"
    exit 1
fi

# Create resource group
log_info "Creating resource group..."
az group create --name "$RG_NAME" --location "$LOCATION" --tags Project=AZ104 Environment=Learning

# Deploy infrastructure
log_info "Deploying infrastructure..."
DEPLOYMENT_NAME="multivnet-$(date +%Y%m%d-%H%M%S)"

az deployment group create \
  --resource-group "$RG_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --parameters "$PARAMETERS_FILE" \
  --name "$DEPLOYMENT_NAME" \
  --verbose

if [ $? -eq 0 ]; then
    log_success "Deployment completed successfully!"
    
    # Get outputs
    log_info "Retrieving deployment outputs..."
    az deployment group show \
      --resource-group "$RG_NAME" \
      --name "$DEPLOYMENT_NAME" \
      --query properties.outputs
else
    log_error "Deployment failed!"
    exit 1
fi

echo "==========================================="
echo "🎉 Azure Multi-VNet Architecture Ready!"
echo "View resources: https://portal.azure.com"
echo "==========================================="