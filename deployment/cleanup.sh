#!/bin/bash

# ===================================
# Azure Multi-VNet Architecture Cleanup Script
# Safely removes all deployed resources
# ===================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Helper functions
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

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

# Configuration
RG_NAME="az104-learn-dns-rg1"
DNS_ZONE_NAME="az104lab.internal"

# Cleanup options
CLEANUP_MODE="interactive"  # interactive, force, or dry-run
PRESERVE_SSH_KEYS=true
CLEANUP_LOGS=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            CLEANUP_MODE="force"
            shift
            ;;
        --dry-run)
            CLEANUP_MODE="dry-run"
            shift
            ;;
        --preserve-ssh-keys)
            PRESERVE_SSH_KEYS=true
            shift
            ;;
        --delete-ssh-keys)
            PRESERVE_SSH_KEYS=false
            shift
            ;;
        --no-logs)
            CLEANUP_LOGS=false
            shift
            ;;
        --help)
            echo "Azure Multi-VNet Architecture Cleanup Script"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force              Skip confirmation prompts"
            echo "  --dry-run           Show what would be deleted without deleting"
            echo "  --preserve-ssh-keys  Keep SSH keys (default)"
            echo "  --delete-ssh-keys    Delete SSH keys as well"
            echo "  --no-logs           Don't save cleanup logs"
            echo "  --help              Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                   # Interactive cleanup"
            echo "  $0 --dry-run         # See what would be deleted"
            echo "  $0 --force           # Force cleanup without prompts"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ===================================
# BANNER AND WARNINGS
# ===================================

echo "=================================================="
echo "🧹 Azure Multi-VNet Architecture Cleanup Script"
echo "=================================================="
echo

if [[ $CLEANUP_MODE == "dry-run" ]]; then
    log_info "DRY RUN MODE - No resources will be deleted"
    echo
fi

# Check if logged into Azure
if ! az account show &> /dev/null; then
    log_error "Please log in to Azure CLI first: az login"
    exit 1
fi

# Get current subscription info
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "Current Azure Subscription:"
echo "  Name: $SUBSCRIPTION_NAME"
echo "  ID: $SUBSCRIPTION_ID"
echo

# ===================================
# RESOURCE DISCOVERY
# ===================================

log_step "Discovering resources to cleanup..."

# Check if resource group exists
if ! az group show --name "$RG_NAME" &> /dev/null; then
    log_warning "Resource group '$RG_NAME' not found. Nothing to cleanup."
    exit 0
fi

# Get resource inventory
RESOURCES=$(az resource list --resource-group "$RG_NAME" --query '[].{Name:name,Type:type,Location:location}' -o json 2>/dev/null || echo "[]")
RESOURCE_COUNT=$(echo "$RESOURCES" | jq -r '. | length')

if [[ $RESOURCE_COUNT -eq 0 ]]; then
    log_warning "No resources found in resource group '$RG_NAME'"
    if [[ $CLEANUP_MODE != "dry-run" ]]; then
        read -p "Delete empty resource group? (y/N): " delete_rg
        if [[ $delete_rg =~ ^[Yy]$ ]]; then
            az group delete --name "$RG_NAME" --yes
            log_success "Empty resource group deleted"
        fi
    fi
    exit 0
fi

# Display resources to be deleted
echo "📋 Resources discovered in '$RG_NAME':"
echo "$RESOURCES" | jq -r '.[] | "  • \(.Name) (\(.Type))"'
echo
echo "Total resources: $RESOURCE_COUNT"
echo

# ===================================
# COST ESTIMATE
# ===================================

log_step "Estimating potential cost savings..."

# Get rough cost estimate (this is approximate)
echo "💰 Estimated monthly costs being removed:"
echo "  • VMSS Instances (1-10): ~$30-300 CAD"
echo "  • Application Gateway WAF_v2: ~$150 CAD"  
echo "  • Standard Load Balancer: ~$25 CAD"
echo "  • Jump Box + Backend VMs: ~$90 CAD"
echo "  • Public IP Addresses: ~$15 CAD"
echo "  • VNet/DNS/Storage: ~$10 CAD"
echo "  Total Estimated Savings: ~$320-590 CAD/month"
echo

# ===================================
# CONFIRMATION
# ===================================

if [[ $CLEANUP_MODE == "interactive" ]]; then
    log_warning "⚠️  DESTRUCTIVE ACTION WARNING ⚠️"
    echo
    echo "This will permanently DELETE the following:"
    echo "  • Resource Group: $RG_NAME"
    echo "  • All $RESOURCE_COUNT resources within it"
    echo "  • All data stored in those resources"
    echo "  • Network configurations and security rules"
    echo "  • Virtual machines and their disks"
    echo
    log_error "THIS ACTION CANNOT BE UNDONE!"
    echo

    # Multiple confirmation prompts for safety
    read -p "Do you understand this will delete everything? (yes/no): " confirm1
    if [[ $confirm1 != "yes" ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi

    read -p "Type the resource group name to confirm: " confirm_rg
    if [[ $confirm_rg != "$RG_NAME" ]]; then
        log_error "Resource group name mismatch. Cleanup cancelled."
        exit 1
    fi

    read -p "Final confirmation - proceed with deletion? (yes/no): " final_confirm
    if [[ $final_confirm != "yes" ]]; then
        echo "Cleanup cancelled by user."
        exit 0
    fi
fi

# ===================================
# BACKUP IMPORTANT INFORMATION
# ===================================

if [[ $CLEANUP_MODE != "dry-run" && $CLEANUP_LOGS == true ]]; then
    log_step "Backing up configuration information..."
    
    BACKUP_DIR="./cleanup-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Export resource configurations
    log_info "Exporting resource configurations..."
    az group export --name "$RG_NAME" > "$BACKUP_DIR/resource-group-template.json" 2>/dev/null || true
    
    # Export DNS records
    if az network private-dns zone show --resource-group "$RG_NAME" --name "$DNS_ZONE_NAME" &> /dev/null; then
        log_info "Backing up DNS records..."
        az network private-dns record-set list --resource-group "$RG_NAME" --zone-name "$DNS_ZONE_NAME" \
            > "$BACKUP_DIR/dns-records.json" 2>/dev/null || true
    fi
    
    # Export NSG rules
    log_info "Backing up security group rules..."
    az network nsg list --resource-group "$RG_NAME" \
        --query '[].{Name:name,Rules:securityRules}' \
        > "$BACKUP_DIR/nsg-rules.json" 2>/dev/null || true
    
    # Export public IPs for reference
    log_info "Backing up public IP information..."
    az network public-ip list --resource-group "$RG_NAME" \
        --query '[].{Name:name,IP:ipAddress,FQDN:dnsSettings.fqdn}' \
        > "$BACKUP_DIR/public-ips.json" 2>/dev/null || true
    
    # Create cleanup summary
    cat > "$BACKUP_DIR/cleanup-summary.txt" << EOF
Azure Multi-VNet Architecture Cleanup Summary
==============================================

Cleanup Date: $(date)
Resource Group: $RG_NAME
Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)
Resources Deleted: $RESOURCE_COUNT

Architecture Components Removed:
- VNet1 (Frontend/Web Tier): 10.0.0.0/16
- VNet2 (Backend Tier): 10.1.0.0/16  
- VMSS Web Servers with Auto-scaling
- Application Gateway with WAF
- Azure Load Balancer
- Jump Box Management VM
- Backend and Database VMs
- Private DNS Zone: $DNS_ZONE_NAME
- VNet Peering Configuration
- Network Security Groups
- Public IP Addresses

To redeploy this architecture:
1. Use the backed up template: resource-group-template.json
2. Or use the original Bicep template from the repository
3. Restore DNS records from: dns-records.json
4. Reconfigure NSG rules from: nsg-rules.json

Note: SSH keys and local configurations were preserved.
EOF
    
    log_success "Configuration backed up to: $BACKUP_DIR"
fi

# ===================================
# RESOURCE CLEANUP
# ===================================

if [[ $CLEANUP_MODE == "dry-run" ]]; then
    log_info "DRY RUN: Would delete resource group '$RG_NAME' and all $RESOURCE_COUNT resources"
    echo
    echo "Specific resources that would be deleted:"
    echo "$RESOURCES" | jq -r '.[] | "  🗑️  \(.Name) (\(.Type))"'
    echo
    log_info "To perform actual cleanup, run without --dry-run flag"
    exit 0
fi

log_step "Starting resource cleanup..."

# Record start time
START_TIME=$(date +%s)

# Delete the entire resource group (fastest method)
log_info "Initiating resource group deletion..."
echo "This will take 10-15 minutes to complete..."

if az group delete --name "$RG_NAME" --yes --no-wait; then
    log_success "Resource group deletion initiated successfully"
    
    # Monitor deletion progress (optional)
    if [[ $CLEANUP_MODE == "interactive" ]]; then
        echo
        read -p "Monitor deletion progress? (y/N): " monitor
        if [[ $monitor =~ ^[Yy]$ ]]; then
            log_info "Monitoring deletion progress (Ctrl+C to stop monitoring)..."
            echo "Progress indicators:"
            
            while az group show --name "$RG_NAME" &>/dev/null; do
                echo -n "."
                sleep 30
            done
            echo
            log_success "Resource group deletion completed!"
        else
            echo
            log_info "Deletion running in background. Check Azure Portal for progress."
        fi
    fi
else
    log_error "Failed to initiate resource group deletion"
    exit 1
fi

# ===================================
# SSH KEY CLEANUP (OPTIONAL)
# ===================================

if [[ $PRESERVE_SSH_KEYS == false ]]; then
    log_step "Cleaning up SSH keys..."
    
    SSH_KEY_PATH="$HOME/.ssh/az104-learn-dns-secure-jumpbox-key"
    if [[ -f "$SSH_KEY_PATH" ]]; then
        if [[ $CLEANUP_MODE == "force" ]] || read -p "Delete SSH key files? (y/N): " delete_keys; then
            if [[ $delete_keys =~ ^[Yy]$ ]] || [[ $CLEANUP_MODE == "force" ]]; then
                rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
                log_success "SSH key files deleted"
            fi
        fi
    fi
fi

# ===================================
# CLEANUP VERIFICATION
# ===================================

log_step "Verifying cleanup completion..."

# Wait a moment for deletion to propagate
sleep 10

if ! az group show --name "$RG_NAME" &>/dev/null; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo
    echo "=================================================="
    log_success "🎉 CLEANUP COMPLETED SUCCESSFULLY!"
    echo "=================================================="
    echo
    echo "Summary:"
    echo "  • Resource Group: $RG_NAME - ✅ DELETED"
    echo "  • Resources Removed: $RESOURCE_COUNT"
    echo "  • Duration: $DURATION seconds"
    echo "  • Est. Monthly Savings: ~$320-590 CAD"
    
    if [[ $CLEANUP_LOGS == true && -d "$BACKUP_DIR" ]]; then
        echo "  • Backup Location: $BACKUP_DIR"
    fi
    
    if [[ $PRESERVE_SSH_KEYS == true ]]; then
        echo "  • SSH Keys: Preserved"
    fi
    
    echo
    echo "✨ Your Azure subscription is now clean!"
    echo "💡 To redeploy: Use the Bicep template or backed up configurations"
    echo "📊 Check Azure Portal to confirm resource removal"
    
else
    log_warning "Resource group still exists. Deletion may still be in progress."
    echo "Check Azure Portal for current status: https://portal.azure.com"
fi

echo
echo "=================================================="
echo "🧹 Cleanup Script Completed"
echo "=================================================="

