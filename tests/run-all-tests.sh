#!/bin/bash
set -e

echo "🧪 Azure Multi-VNet Architecture - Test Suite"
echo "=============================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# Test configuration
RG_NAME="az104-learn-dns-rg1"
DNS_ZONE="az104lab.internal"

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    log_info "Running: $test_name"
    
    if eval "$test_command" &>/dev/null; then
        log_success "$test_name"
        ((TESTS_PASSED++))
    else
        log_error "$test_name"
        ((TESTS_FAILED++))
    fi
}

echo
log_info "Starting test execution..."

# Infrastructure Tests
echo "🏗️ Infrastructure Tests"
run_test "Resource Group Exists" "az group show --name $RG_NAME"
run_test "VNet1 Deployed" "az network vnet show --resource-group $RG_NAME --name vnet1"
run_test "VNet2 Deployed" "az network vnet show --resource-group $RG_NAME --name vnet2"
run_test "VNet Peering Active" "az network vnet peering show --resource-group $RG_NAME --vnet-name vnet1 --name vnet1-to-vnet2 --query 'peeringState' -o tsv | grep -q Connected"

# DNS Tests
echo
echo "🌐 DNS Tests"
run_test "Private DNS Zone Exists" "az network private-dns zone show --resource-group $RG_NAME --name $DNS_ZONE"
run_test "VNet1 DNS Link" "az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE --name vnet1-link"
run_test "VNet2 DNS Link" "az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE --name vnet2-link"

# Compute Tests  
echo
echo "💻 Compute Tests"
run_test "Jump Box Running" "az vm get-instance-view --resource-group $RG_NAME --name jumpbox-vm --query 'instanceView.statuses[?code==\`PowerState/running\`]' -o tsv | grep -q running"
run_test "VMSS Deployed" "az vmss show --resource-group $RG_NAME --name web-vmss"
run_test "Backend VM Running" "az vm get-instance-view --resource-group $RG_NAME --name backend-vm --query 'instanceView.statuses[?code==\`PowerState/running\`]' -o tsv | grep -q running"

# Load Balancing Tests
echo
echo "⚖️ Load Balancing Tests"
run_test "Load Balancer Deployed" "az network lb show --resource-group $RG_NAME --name web-vmss-lb"
run_test "Application Gateway Deployed" "az network application-gateway show --resource-group $RG_NAME --name web-appgw"
run_test "WAF Policy Applied" "az network application-gateway waf-policy show --resource-group $RG_NAME --name web-appgw-waf-policy"

# Security Tests
echo
echo "🔒 Security Tests"
run_test "Jump Box NSG Configured" "az network nsg show --resource-group $RG_NAME --name jumpbox-nsg"
run_test "VMSS NSG Configured" "az network nsg show --resource-group $RG_NAME --name web-vmss-nsg"
run_test "VNet2 NSG Configured" "az network nsg show --resource-group $RG_NAME --name vnet2-nsg"

# Summary
echo
echo "=============================================="
echo "📊 Test Results Summary"
echo "=============================================="
echo "Tests Passed: $TESTS_PASSED"
echo "Tests Failed: $TESTS_FAILED"
echo "Success Rate: $(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED) ))%"

if [ $TESTS_FAILED -eq 0 ]; then
    echo
    log_success "🎉 All tests passed! Infrastructure is healthy."
    exit 0
else
    echo
    log_error "❌ Some tests failed. Check the infrastructure."
    exit 1
fi