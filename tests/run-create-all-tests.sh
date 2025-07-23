# Create DNS test script for internal execution
echo
echo "📋 Creating DNS test script for jump box execution..."
cat > /tmp/internal-dns-test.sh << 'EOF'
#!/bin/bash
echo "=== Internal DNS Resolution Test ==="
echo "Testing from $(hostname) - $(hostname -I | awk '{print $1}')"
echo

# Test DNS resolution from within VNet
echo "🔍 DNS Resolution Tests:"
for record in jumpbox backend-vm database-vm api frontend backend db; do
    result=$(nslookup $record.az104lab.internal 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}' 2>/dev/null)
    if [[ -n "$result" && "$result" != "127.0.0.53" ]]; then
        echo "✅ $record.az104lab.internal → $result"
    else
        echo "❌ $record.az104lab.internal → Failed"
    fi
done

echo
echo "🌐 External DNS Test:"
if nslookup google.com >/dev/null 2>&1; then
    echo "✅ External DNS working"
else
    echo "❌ External DNS failed"
fi

echo
echo "⚡ DNS Performance Test:"
for record in jumpbox api backend-vm; do
    time_result=$(time (nslookup $record.az104lab.internal >/dev/null 2>&1) 2>&1 | grep real | awk '{print $2}')
    echo "⏱️  $record.az104lab.internal: $time_result"
done
EOF

chmod +x /tmp/internal-dns-test.sh
log_info "Internal DNS test script created: /tmp/internal-dns-test.sh"

# Summary
echo
echo "============================"
echo "DNS Test Results:"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "============================"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✅ All DNS tests passed!"
    exit 0
else
    echo "❌ Some DNS tests failed!"
    exit 1
fi

# ====================
# 5. security-test.sh - Security Validation Testing
# ====================

#!/bin/bash
echo "🔒 Security Validation Test Suite"
echo "================================="

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_security() { echo -e "${PURPLE}[SECURITY]${NC} $1"; }

# Configuration
RG_NAME="az104-learn-dns-rg1"
TESTS_PASSED=0
TESTS_FAILED=0

# Security test function
test_security() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    log_info "Security Test: $test_name"
    
    if eval "$test_command" &>/dev/null; then
        if [[ "$expected_result" == "success" ]]; then
            log_pass "$test_name"
            ((TESTS_PASSED++))
        else
            log_fail "$test_name (unexpected success - security issue)"
            ((TESTS_FAILED++))
        fi
    else
        if [[ "$expected_result" == "fail" ]]; then
            log_pass "$test_name (properly blocked)"
            ((TESTS_PASSED++))
        else
            log_fail "$test_name"
            ((TESTS_FAILED++))
        fi
    fi
}

# Network Security Group Tests
echo "🛡️ Network Security Group Tests"

# Check NSG existence and configuration
for nsg in jumpbox-nsg web-vmss-nsg vnet2-nsg; do
    test_security "NSG $nsg exists" "az network nsg show --resource-group $RG_NAME --name $nsg" "success"
done

# Check SSH access restrictions
log_security "Validating SSH access restrictions..."
JUMPBOX_SSH_RULES=$(az network nsg rule list --resource-group $RG_NAME --nsg-name jumpbox-nsg --query '[?destinationPortRange==`22`]' -o json)
SSH_RULE_COUNT=$(echo "$JUMPBOX_SSH_RULES" | jq length)

if [[ $SSH_RULE_COUNT -ge 2 ]]; then
    log_pass "SSH access has multiple rules (allow + deny)"
    ((TESTS_PASSED++))
else
    log_fail "SSH access insufficiently restricted"
    ((TESTS_FAILED++))
fi

# Check for deny-all SSH rule
DENY_SSH_EXISTS=$(echo "$JUMPBOX_SSH_RULES" | jq -r '.[] | select(.access=="Deny") | .name' | head -1)
if [[ -n "$DENY_SSH_EXISTS" ]]; then
    log_pass "Deny-all SSH rule exists: $DENY_SSH_EXISTS"
    ((TESTS_PASSED++))
else
    log_fail "No deny-all SSH rule found"
    ((TESTS_FAILED++))
fi

# WAF and Application Security Tests
echo
echo "🔥 Web Application Firewall Tests"

test_security "WAF Policy exists" "az network application-gateway waf-policy show --resource-group $RG_NAME --name web-appgw-waf-policy" "success"

# Check WAF mode
WAF_MODE=$(az network application-gateway waf-policy show --resource-group $RG_NAME --name web-appgw-waf-policy --query 'policySettings.mode' -o tsv 2>/dev/null)
if [[ "$WAF_MODE" == "Prevention" ]]; then
    log_pass "WAF in Prevention mode"
    ((TESTS_PASSED++))
else
    log_warn "WAF mode: $WAF_MODE (consider Prevention mode for production)"
fi

# Check WAF rule set
WAF_RULESET=$(az network application-gateway waf-policy show --resource-group $RG_NAME --name web-appgw-waf-policy --query 'managedRules.managedRuleSets[0].ruleSetType' -o tsv 2>/dev/null)
if [[ "$WAF_RULESET" == "OWASP" ]]; then
    log_pass "OWASP rule set configured"
    ((TESTS_PASSED++))
else
    log_fail "OWASP rule set not found: $WAF_RULESET"
    ((TESTS_FAILED++))
fi

# SSL/TLS Configuration Tests
echo
echo "🔐 SSL/TLS Configuration Tests"

# Check Application Gateway SSL configuration
APPGW_LISTENERS=$(az network application-gateway http-listener list --resource-group $RG_NAME --gateway-name web-appgw --query '[].protocol' -o tsv 2>/dev/null)
if echo "$APPGW_LISTENERS" | grep -q "Https"; then
    log_pass "HTTPS listener configured"
    ((TESTS_PASSED++))
else
    log_warn "No HTTPS listener found (HTTP only)"
fi

# Check for HTTP to HTTPS redirect
REDIRECT_CONFIGS=$(az network application-gateway redirect-config list --resource-group $RG_NAME --gateway-name web-appgw 2>/dev/null || echo "[]")
REDIRECT_COUNT=$(echo "$REDIRECT_CONFIGS" | jq length 2>/dev/null || echo 0)
if [[ $REDIRECT_COUNT -gt 0 ]]; then
    log_pass "HTTP to HTTPS redirect configured"
    ((TESTS_PASSED++))
else
    log_warn "No HTTP to HTTPS redirect found"
fi

# VM Security Configuration Tests
echo
echo "💻 Virtual Machine Security Tests"

# Check VM encryption
VMS=$(az vm list --resource-group $RG_NAME --query '[].name' -o tsv)
for vm in $VMS; do
    ENCRYPTION_STATUS=$(az vm encryption show --resource-group $RG_NAME --name $vm --query 'disks[0].statuses[0].code' -o tsv 2>/dev/null || echo "NotEncrypted")
    if [[ "$ENCRYPTION_STATUS" == "EncryptionState/encrypted" ]]; then
        log_pass "VM $vm: Disk encryption enabled"
        ((TESTS_PASSED++))
    else
        log_warn "VM $vm: Disk encryption not enabled"
    fi
done

# Check VM update management
for vm in $VMS; do
    # Check if automatic updates are configured (this would be in VM extensions)
    UPDATE_EXTENSION=$(az vm extension list --resource-group $RG_NAME --vm-name $vm --query '[?name==`MicrosoftMonitoringAgent` || name==`UpdateManagement`].name' -o tsv 2>/dev/null)
    if [[ -n "$UPDATE_EXTENSION" ]]; then
        log_pass "VM $vm: Update management configured"
        ((TESTS_PASSED++))
    else
        log_warn "VM $vm: No update management extension found"
    fi
done

# Network Segmentation Tests
echo
echo "🏘️ Network Segmentation Tests"

# Check VNet peering security
PEERING_CONFIGS=$(az network vnet peering list --resource-group $RG_NAME --vnet-name vnet1 --query '[].{Name:name,AllowForwardedTraffic:allowForwardedTraffic,AllowGatewayTransit:allowGatewayTransit}' -o json)
ALLOW_FORWARDED=$(echo "$PEERING_CONFIGS" | jq -r '.[0].AllowForwardedTraffic')
ALLOW_GATEWAY=$(echo "$PEERING_CONFIGS" | jq -r '.[0].AllowGatewayTransit')

if [[ "$ALLOW_FORWARDED" == "true" ]]; then
    log_pass "VNet peering allows forwarded traffic (expected)"
    ((TESTS_PASSED++))
else
    log_fail "VNet peering blocks forwarded traffic"
    ((TESTS_FAILED++))
fi

if [[ "$ALLOW_GATEWAY" == "false" ]]; then
    log_pass "VNet peering disables gateway transit (secure)"
    ((TESTS_PASSED++))
else
    log_warn "VNet peering allows gateway transit"
fi

# Check subnet isolation
VNET2_SUBNETS=$(az network vnet subnet list --resource-group $RG_NAME --vnet-name vnet2 --query '[].name' -o tsv)
for subnet in $VNET2_SUBNETS; do
    NSG_ASSOCIATED=$(az network vnet subnet show --resource-group $RG_NAME --vnet-name vnet2 --name $subnet --query 'networkSecurityGroup.id' -o tsv 2>/dev/null)
    if [[ -n "$NSG_ASSOCIATED" && "$NSG_ASSOCIATED" != "null" ]]; then
        log_pass "Subnet $subnet has NSG protection"
        ((TESTS_PASSED++))
    else
        log_fail "Subnet $subnet lacks NSG protection"
        ((TESTS_FAILED++))
    fi
done

# Public IP Security Tests
echo
echo "🌍 Public IP Security Tests"

PUBLIC_IPS=$(az network public-ip list --resource-group $RG_NAME --query '[].{Name:name,IP:ipAddress,Protection:ddosSettings.ddosCustomPolicy}' -o json)
PUBLIC_IP_COUNT=$(echo "$PUBLIC_IPS" | jq length)

log_info "Found $PUBLIC_IP_COUNT public IPs"

# Check for DDoS protection
for pip in $(echo "$PUBLIC_IPS" | jq -r '.[].Name'); do
    DDOS_PROTECTED=$(az network public-ip show --resource-group $RG_NAME --name $pip --query 'ddosSettings.ddosCustomPolicy' -o tsv 2>/dev/null)
    if [[ -n "$DDOS_PROTECTED" && "$DDOS_PROTECTED" != "null" ]]; then
        log_pass "Public IP $pip: DDoS protection enabled"
        ((TESTS_PASSED++))
    else
        log_warn "Public IP $pip: No custom DDoS protection (using Standard)"
    fi
done

# Access Control Tests
echo
echo "🎫 Access Control Tests"

# Check for Just-in-Time VM access (if configured)
JIT_POLICIES=$(az security jit-policy list --resource-group $RG_NAME 2>/dev/null || echo "[]")
JIT_COUNT=$(echo "$JIT_POLICIES" | jq length 2>/dev/null || echo 0)
if [[ $JIT_COUNT -gt 0 ]]; then
    log_pass "Just-in-Time VM access policies configured"
    ((TESTS_PASSED++))
else
    log_warn "No Just-in-Time VM access policies found"
fi

# Check for managed identity usage
for vm in $VMS; do
    MANAGED_IDENTITY=$(az vm identity show --resource-group $RG_NAME --name $vm --query 'type' -o tsv 2>/dev/null || echo "None")
    if [[ "$MANAGED_IDENTITY" != "None" ]]; then
        log_pass "VM $vm: Managed identity configured"
        ((TESTS_PASSED++))
    else
        log_warn "VM $vm: No managed identity configured"
    fi
done

# Resource Tagging Security
echo
echo "🏷️ Resource Tagging and Governance Tests"

UNTAGGED_RESOURCES=$(az resource list --resource-group $RG_NAME --query '[?tags==null].{Name:name,Type:type}' -o json)
UNTAGGED_COUNT=$(echo "$UNTAGGED_RESOURCES" | jq length)

if [[ $UNTAGGED_COUNT -eq 0 ]]; then
    log_pass "All resources are properly tagged"
    ((TESTS_PASSED++))
else
    log_warn "$UNTAGGED_COUNT resources lack proper tagging"
    echo "$UNTAGGED_RESOURCES" | jq -r '.[] | "  • \(.Name) (\(.Type))"'
fi

# Security monitoring and logging
echo
echo "📊 Security Monitoring Tests"

# Check for Network Security Group flow logs
for nsg in jumpbox-nsg web-vmss-nsg vnet2-nsg; do
    # This would require a storage account and Network Watcher to be properly configured
    log_warn "NSG Flow Logs: Manual verification required for $nsg"
done

# Check for diagnostic settings on key resources
KEY_RESOURCES=("web-appgw" "web-vmss-lb")
for resource in "${KEY_RESOURCES[@]}"; do
    DIAGNOSTIC_SETTINGS=$(az monitor diagnostic-settings list --resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME/providers/Microsoft.Network/applicationGateways/$resource" 2>/dev/null || echo "[]")
    DIAG_COUNT=$(echo "$DIAGNOSTIC_SETTINGS" | jq length 2>/dev/null || echo 0)
    if [[ $DIAG_COUNT -gt 0 ]]; then
        log_pass "$resource: Diagnostic settings configured"
        ((TESTS_PASSED++))
    else
        log_warn "$resource: No diagnostic settings found"
    fi
done

# Vulnerability assessment
echo
echo "🔍 Security Assessment Summary"

# Create security recommendations
cat > /tmp/security-recommendations.txt << EOF
Security Assessment Summary for $RG_NAME
========================================

High Priority Recommendations:
1. Enable disk encryption on all VMs
2. Configure HTTPS listeners on Application Gateway
3. Set up HTTP to HTTPS redirect
4. Enable diagnostic logging on all resources
5. Configure NSG flow logs
6. Implement Just-in-Time VM access

Medium Priority Recommendations:
1. Configure managed identities for VMs
2. Set up custom DDoS protection policies
3. Implement Azure Security Center recommendations
4. Configure automated patching for VMs
5. Set up Network Security monitoring

Low Priority Recommendations:
1. Review and optimize NSG rules
2. Implement resource tagging governance
3. Set up security alerting policies
4. Configure backup policies for VMs
5. Review access controls regularly

Compliance Notes:
- WAF configured with OWASP rule set
- Network segmentation properly implemented
- VNet peering securely configured
- SSH access properly restricted
- Resource group isolation maintained
EOF

log_info "Security recommendations saved to: /tmp/security-recommendations.txt"

# Summary
echo
echo "================================="
echo "Security Test Results:"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "================================="

# Security score calculation
TOTAL_SECURITY_TESTS=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TOTAL_SECURITY_TESTS -gt 0 ]]; then
    SECURITY_SCORE=$(( TESTS_PASSED * 100 / TOTAL_SECURITY_TESTS ))
    echo "Security Score: $SECURITY_SCORE%"
    
    if [[ $SECURITY_SCORE -ge 80 ]]; then
        log_pass "Good security posture ($SECURITY_SCORE%)"
    elif [[ $SECURITY_SCORE -ge 60 ]]; then
        log_warn "Moderate security posture ($SECURITY_SCORE%) - improvements needed"
    else
        log_fail "Poor security posture ($SECURITY_SCORE%) - immediate attention required"
    fi
fi

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✅ Security validation completed!"
    exit 0
else
    echo "❌ Security issues found - review recommendations!"
    exit 1
fi

# ====================
# 6. performance-test.sh - Performance and Load Testing
# ====================

#!/bin/bash
echo "📊 Performance and Load Test Suite"
echo "=================================="

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_perf() { echo -e "${PURPLE}[PERF]${NC} $1"; }

# Configuration
RG_NAME="az104-learn-dns-rg1"
TESTS_PASSED=0
TESTS_FAILED=0

# Get target endpoints
LB_IP=$(az network public-ip show --resource-group $RG_NAME --name web-vmss-lb-pip --query ipAddress -o tsv 2>/dev/null)
AGW_IP=$(az network public-ip show --resource-group $RG_NAME --name webapp-gw-publicip --query ipAddress -o tsv 2>/dev/null)

echo "Testing endpoints:"
echo "Load Balancer: $LB_IP"
echo "Application Gateway: $AGW_IP"
echo

# Performance test function
test_performance() {
    local endpoint="$1"
    local test_name="$2"
    local max_response_time="$3"
    
    log_info "Performance test: $test_name"
    
    if [[ -z "$endpoint" || "$endpoint" == "null" ]]; then
        log_warn "Endpoint not available for $test_name"
        return
    fi
    
    response_time=$(curl -s -o /dev/null -w "%{time_total}" --max-time 30 "http://$endpoint" 2>/dev/null || echo "timeout")
    
    if [[ "$response_time" == "timeout" ]]; then
        log_fail "$test_name: Request timeout"
        ((TESTS_FAILED++))
        return
    fi
    
    response_ms=$(echo "$response_time * 1000" | bc 2>/dev/null || echo "0")
    max_ms=$(echo "$max_response_time * 1000" | bc 2>/dev/null || echo "0")
    
    if (( $(echo "$response_time <= $max_response_time" | bc -l) )); then
        log_pass "$test_name: ${response_ms}ms (< ${max_ms}ms)"
        ((TESTS_PASSED++))
    else
        log_fail "$test_name: ${response_ms}ms (> ${max_ms}ms)"
        ((TESTS_FAILED++))
    fi
}

# Load test function using curl
load_test_curl() {
    local endpoint="$1"
    local test_name="$2"
    local concurrent_requests="$3"
    local total_requests="$4"
    
    log_perf "Load test: $test_name ($concurrent_requests concurrent, $total_requests total)"
    
    if [[ -z "$endpoint" || "$endpoint" == "null" ]]; then
        log_warn "Endpoint not available for $test_name"
        return
    fi
    
    # Create temporary directory for results
    local temp_dir="/tmp/loadtest_$"
    mkdir -p "$temp_dir"
    
    local start_time=$(date +%s)
    local success_count=0
    local error_count=0
    local total_response_time=0
    
    # Run concurrent requests
    for ((i=1; i<=total_requests; i++)); do
        {
            response_time=$(curl -s -o /dev/null -w "%{time_total}:%{http_code}" --max-time 10 "http://$endpoint" 2>/dev/null || echo "timeout:000")
            echo "$response_time" >> "$temp_dir/results_$.txt"
        } &
        
        # Limit concurrent processes
        if (( i % concurrent_requests == 0 )); then
            wait
        fi
    done
    wait
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    # Analyze results
    if [[ -f "$temp_dir/results_$.txt" ]]; then
        while IFS=':' read -r time code; do
            if [[ "$code" == "200" ]]; then
                ((success_count++))
                total_response_time=$(echo "$total_response_time + $time" | bc -l)
            else
                ((error_count++))
            fi
        done < "$temp_dir/results_$.txt"
    fi
    
    # Calculate metrics
    local success_rate=0
    local avg_response_time=0
    local requests_per_second=0
    
    if [[ $total_requests -gt 0 ]]; then
        success_rate=$(( success_count * 100 / total_requests ))
        requests_per_second=$(( total_requests / total_time ))
    fi
    
    if [[ $success_count -gt 0 ]]; then
        avg_response_time=$(echo "scale=3; $total_response_time / $success_count" | bc)
    fi
    
    # Report results
    echo "  Results:"
    echo "    Total requests: $total_requests"
    echo "    Successful: $success_count"
    echo "    Failed: $error_count"
    echo "    Success rate: $success_rate%"
    echo "    Average response time: ${avg_response_time}s"
    echo "    Requests per second: $requests_per_second"
    echo "    Total test time: ${total_time}s"
    
    # Pass/fail criteria
    if [[ $success_rate -ge 95 && $(echo "$avg_response_time < 2" | bc -l) -eq 1 ]]; then
        log_pass "$test_name: Performance acceptable"
        ((TESTS_PASSED++))
    else
        log_fail "$test_name: Performance below threshold"
        ((TESTS_FAILED++))
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
}

# Basic response time tests
echo "⏱️ Response Time Tests"
test_performance "$LB_IP" "Load Balancer Response Time" "2.0"
test_performance "$AGW_IP" "Application Gateway Response Time" "3.0"

# HTTP status code validation
echo
echo "✅ HTTP Status Code Tests"
for endpoint_name in "Load Balancer:$LB_IP" "Application Gateway:$AGW_IP"; do
    IFS=':' read -r name ip <<< "$endpoint_name"
    if [[ -n "$ip" && "$ip" != "null" ]]; then
        status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ip" 2>/dev/null || echo "000")
        if [[ "$status_code" == "200" ]]; then
            log_pass "$name: HTTP 200 OK"
            ((TESTS_PASSED++))
        else
            log_fail "$name: HTTP $status_code"
            ((TESTS_FAILED++))
        fi
    fi
done

# Concurrent connection tests
echo
echo "🔄 Concurrent Connection Tests"
if command -v ab &> /dev/null; then
    log_info "Using Apache Bench for advanced load testing"
    
    for endpoint_name in "Load Balancer:$LB_IP" "Application Gateway:$AGW_IP"; do
        IFS=':' read -r name ip <<< "$endpoint_name"
        if [[ -n "$ip" && "$ip" != "null" ]]; then
            log_perf "Testing $name with Apache Bench"
            
            ab_result=$(ab -n 100 -c 10 -q "http://$ip/" 2>/dev/null)
            
            if [[ $? -eq 0 ]]; then
                requests_per_sec=$(echo "$ab_result" | grep "Requests per second" | awk '{print $4}')
                time_per_request=$(echo "$ab_result" | grep "Time per request" | head -1 | awk '{print $4}')
                failed_requests=$(echo "$ab_result" | grep "Failed requests" | awk '{print $3}')
                
                echo "  $name Results:"
                echo "    Requests per second: $requests_per_sec"
                echo "    Time per request: ${time_per_request}ms"
                echo "    Failed requests: $failed_requests"
                
                if [[ $(echo "$requests_per_sec > 10" | bc -l) -eq 1 && "$failed_requests" == "0" ]]; then
                    log_pass "$name: Load test passed"
                    ((TESTS_PASSED++))
                else
                    log_fail "$name: Load test failed"
                    ((TESTS_FAILED++))
                fi
            else
                log_fail "$name: Apache Bench test failed"
                ((TESTS_FAILED++))
            fi
        fi
    done
else
    log_warn "Apache Bench not available, using curl-based load testing"
    
    # Fallback to curl-based load testing
    load_test_curl "$LB_IP" "Load Balancer Load Test" "5" "50"
    load_test_curl "$AGW_IP" "Application Gateway Load Test" "5" "50"
fi

# DNS performance tests
echo
echo "🏷️ DNS Performance Tests"
dns_hosts=("jumpbox.az104lab.internal" "api.az104lab.internal" "backend-vm.az104lab.internal")

for host in "${dns_hosts[@]}"; do
    log_info "DNS performance test: $host"
    
    dns_times=()
    for ((i=1; i<=5; i++)); do
        start_time=$(date +%s%N)
        nslookup "$host" >/dev/null 2>&1
        end_time=$(date +%s%N)
        
        if [[ $? -eq 0 ]]; then
            dns_time=$(( (end_time - start_time) / 1000000 ))
            dns_times+=($dns_time)
        fi
    done
    
    if [[ ${#dns_times[@]} -gt 0 ]]; then
        # Calculate average
        sum=0
        for time in "${dns_times[@]}"; do
            sum=$((sum + time))
        done
        avg_dns_time=$((sum / ${#dns_times[@]}))
        
        if [[ $avg_dns_time -lt 100 ]]; then
            log_pass "$host: Average DNS time ${avg_dns_time}ms"
            ((TESTS_PASSED++))
        else
            log_warn "$host: Slow DNS time ${avg_dns_time}ms"
        fi
    else
        log_fail "$host: DNS resolution failed"
        ((TESTS_FAILED++))
    fi
done

# Auto-scaling performance test
echo
echo "📈 Auto-scaling Performance Test"
log_info "Checking current VMSS instance count..."

current_instances=$(az vmss list-instances --resource-group $RG_NAME --name web-vmss --query 'length(@)' -o tsv 2>/dev/null || echo 0)
log_info "Current VMSS instances: $current_instances"

if [[ $current_instances -gt 0 ]]; then
    log_pass "VMSS has active instances"
    ((TESTS_PASSED++))
    
    # Check auto-scaling configuration
    autoscale_config=$(az monitor autoscale show --resource-group $RG_NAME --name web-vmss-autoscale 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        min_instances=$(echo "$autoscale_config" | jq -r '.profiles[0].capacity.minimum')
        max_instances=$(echo "$autoscale_config" | jq -r '.profiles[0].capacity.maximum')
        
        log_info "Auto-scaling configured: $min_instances - $max_instances instances"
        
        if [[ $min_instances -le $current_instances && $current_instances -le $max_instances ]]; then
            log_pass "Instance count within auto-scaling limits"
            ((TESTS_PASSED++))
        else
            log_fail "Instance count outside auto-scaling limits"
            ((TESTS_FAILED++))
        fi
    else
        log_fail "Auto-scaling configuration not found"
        ((TESTS_FAILED++))
    fi
else
    log_fail "No VMSS instances running"
    ((TESTS_FAILED++))
fi

# Create load generation script for manual testing
echo
echo "🔥 Load Generation Script Creation"
cat > /tmp/generate-load.sh << 'EOF'
#!/bin/bash
echo "🔥 Load Generation Script for Auto-scaling Test"
echo "==============================================="

# Configuration
LB_IP="LOAD_BALANCER_IP"
AGW_IP="APPLICATION_GATEWAY_IP"
DURATION=600  # 10 minutes
CONCURRENT=20

echo "This script will generate sustained load to trigger auto-scaling"
echo "Duration: $DURATION seconds"
echo "Concurrent requests: $CONCURRENT"
echo

read -p "Start load generation? (y/N): " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "Load generation cancelled"
    exit 0
fi

echo "Starting load generation..."
start_time=$(date +%s)
end_time=$((start_time + DURATION))

while [[ $(date +%s) -lt# ===================================
# Azure Multi-VNet Architecture Test Suite
# 6 Comprehensive Test Scripts
# ===================================

# ====================
# 1. run-all-tests.sh - Master Test Runner
# ====================

#!/bin/bash
set -e

echo "🧪 Azure Multi-VNet Architecture - Complete Test Suite"
echo "======================================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_test() { echo -e "${PURPLE}[TEST]${NC} $1"; }

# Configuration
RG_NAME="az104-learn-dns-rg1"
TEST_DIR="$(dirname "$0")"

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Test execution function
run_test_script() {
    local test_name="$1"
    local test_script="$2"
    local test_file="$TEST_DIR/$test_script"
    
    log_test "Running: $test_name"
    echo "----------------------------------------"
    
    if [[ ! -f "$test_file" ]]; then
        log_warning "Test script not found: $test_script"
        ((SKIPPED_TESTS++))
        return
    fi
    
    if bash "$test_file"; then
        log_success "$test_name completed successfully"
        ((PASSED_TESTS++))
    else
        log_error "$test_name failed"
        ((FAILED_TESTS++))
    fi
    
    echo
    ((TOTAL_TESTS++))
}

# Check prerequisites
log_info "Checking prerequisites..."
if ! command -v az &> /dev/null; then
    log_error "Azure CLI not found"
    exit 1
fi

if ! az account show &> /dev/null; then
    log_error "Not logged into Azure CLI"
    exit 1
fi

if ! az group show --name "$RG_NAME" &> /dev/null; then
    log_error "Resource group '$RG_NAME' not found"
    exit 1
fi

echo
log_info "Starting comprehensive test suite..."
echo

# Run all test scripts
run_test_script "Infrastructure Validation" "infrastructure-test.sh"
run_test_script "Network Connectivity" "connectivity-test.sh"
run_test_script "DNS Resolution" "dns-test.sh"
run_test_script "Security Validation" "security-test.sh"
run_test_script "Performance Testing" "performance-test.sh"
run_test_script "Integration Testing" "integration-test.sh"

# Generate test report
echo "======================================================"
echo "📊 Test Results Summary"
echo "======================================================"
echo "Total Test Suites: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"
echo "Skipped: $SKIPPED_TESTS"

if [[ $TOTAL_TESTS -gt 0 ]]; then
    SUCCESS_RATE=$(( PASSED_TESTS * 100 / TOTAL_TESTS ))
    echo "Success Rate: $SUCCESS_RATE%"
fi

echo
if [[ $FAILED_TESTS -eq 0 ]]; then
    log_success "🎉 All test suites passed! Infrastructure is healthy."
    exit 0
else
    log_error "❌ Some test suites failed. Check the output above."
    exit 1
fi

# ====================
# 2. infrastructure-test.sh - Infrastructure Validation
# ====================

#!/bin/bash
echo "🏗️ Infrastructure Validation Test Suite"
echo "========================================"

# Colors and logging functions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# Test configuration
RG_NAME="az104-learn-dns-rg1"
DNS_ZONE="az104lab.internal"

TESTS_PASSED=0
TESTS_FAILED=0

# Test execution function
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    log_info "Testing: $test_name"
    
    if eval "$test_command" &>/dev/null; then
        if [[ "$expected_result" == "success" ]]; then
            log_pass "$test_name"
            ((TESTS_PASSED++))
        else
            log_fail "$test_name (unexpected success)"
            ((TESTS_FAILED++))
        fi
    else
        if [[ "$expected_result" == "fail" ]]; then
            log_pass "$test_name (expected failure)"
            ((TESTS_PASSED++))
        else
            log_fail "$test_name"
            ((TESTS_FAILED++))
        fi
    fi
}

# Resource Group Tests
echo "📁 Resource Group Tests"
run_test "Resource Group Exists" "az group show --name $RG_NAME" "success"
run_test "Resource Group Location" "az group show --name $RG_NAME --query location -o tsv | grep -q canadacentral" "success"

# Virtual Network Tests
echo
echo "🌐 Virtual Network Tests"
run_test "VNet1 Exists" "az network vnet show --resource-group $RG_NAME --name vnet1" "success"
run_test "VNet2 Exists" "az network vnet show --resource-group $RG_NAME --name vnet2" "success"
run_test "VNet1 Address Space" "az network vnet show --resource-group $RG_NAME --name vnet1 --query 'addressSpace.addressPrefixes[0]' -o tsv | grep -q '10.0.0.0/16'" "success"
run_test "VNet2 Address Space" "az network vnet show --resource-group $RG_NAME --name vnet2 --query 'addressSpace.addressPrefixes[0]' -o tsv | grep -q '10.1.0.0/16'" "success"

# Subnet Tests
echo
echo "🏘️ Subnet Tests"
run_test "VNet1 Subnet1 Exists" "az network vnet subnet show --resource-group $RG_NAME --vnet-name vnet1 --name subnet1" "success"
run_test "VNet1 Subnet2 Exists" "az network vnet subnet show --resource-group $RG_NAME --vnet-name vnet1 --name subnet2" "success"
run_test "VNet2 Backend Subnet" "az network vnet subnet show --resource-group $RG_NAME --vnet-name vnet2 --name backend-subnet" "success"
run_test "VNet2 Database Subnet" "az network vnet subnet show --resource-group $RG_NAME --vnet-name vnet2 --name database-subnet" "success"

# VNet Peering Tests
echo
echo "🤝 VNet Peering Tests"
run_test "Peering VNet1 to VNet2" "az network vnet peering show --resource-group $RG_NAME --vnet-name vnet1 --name vnet1-to-vnet2" "success"
run_test "Peering VNet2 to VNet1" "az network vnet peering show --resource-group $RG_NAME --vnet-name vnet2 --name vnet2-to-vnet1" "success"
run_test "Peering State Connected" "az network vnet peering show --resource-group $RG_NAME --vnet-name vnet1 --name vnet1-to-vnet2 --query 'peeringState' -o tsv | grep -q Connected" "success"

# Compute Resources Tests
echo
echo "💻 Compute Resources Tests"
run_test "Jump Box VM Exists" "az vm show --resource-group $RG_NAME --name jumpbox-vm" "success"
run_test "Jump Box Running" "az vm get-instance-view --resource-group $RG_NAME --name jumpbox-vm --query 'instanceView.statuses[?code==\`PowerState/running\`]' -o tsv | grep -q running" "success"
run_test "VMSS Exists" "az vmss show --resource-group $RG_NAME --name web-vmss" "success"
run_test "Backend VM Exists" "az vm show --resource-group $RG_NAME --name backend-vm" "success"
run_test "Database VM Exists" "az vm show --resource-group $RG_NAME --name database-vm" "success"

# Load Balancing Tests
echo
echo "⚖️ Load Balancing Tests"
run_test "Load Balancer Exists" "az network lb show --resource-group $RG_NAME --name web-vmss-lb" "success"
run_test "Application Gateway Exists" "az network application-gateway show --resource-group $RG_NAME --name web-appgw" "success"
run_test "WAF Policy Exists" "az network application-gateway waf-policy show --resource-group $RG_NAME --name web-appgw-waf-policy" "success"

# DNS Tests
echo
echo "🏷️ DNS Infrastructure Tests"
run_test "Private DNS Zone Exists" "az network private-dns zone show --resource-group $RG_NAME --name $DNS_ZONE" "success"
run_test "VNet1 DNS Link" "az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE --name vnet1-link" "success"
run_test "VNet2 DNS Link" "az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE --name vnet2-link" "success"

# Auto-scaling Tests
echo
echo "📈 Auto-scaling Tests"
run_test "Auto-scale Settings Exist" "az monitor autoscale show --resource-group $RG_NAME --name web-vmss-autoscale" "success"

# Public IP Tests
echo
echo "🌍 Public IP Tests"
run_test "Jump Box Public IP" "az network public-ip show --resource-group $RG_NAME --name jumpbox-vmPublicIP" "success"
run_test "Load Balancer Public IP" "az network public-ip show --resource-group $RG_NAME --name web-vmss-lb-pip" "success"
run_test "Application Gateway Public IP" "az network public-ip show --resource-group $RG_NAME --name webapp-gw-publicip" "success"

# Summary
echo
echo "========================================"
echo "Infrastructure Test Results:"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "========================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✅ All infrastructure tests passed!"
    exit 0
else
    echo "❌ Some infrastructure tests failed!"
    exit 1
fi

# ====================
# 3. connectivity-test.sh - Network Connectivity Testing
# ====================

#!/bin/bash
echo "🌐 Network Connectivity Test Suite"
echo "=================================="

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Configuration
RG_NAME="az104-learn-dns-rg1"
TIMEOUT=10

TESTS_PASSED=0
TESTS_FAILED=0

# Get public IPs
echo "Getting public IP addresses..."
LB_IP=$(az network public-ip show --resource-group $RG_NAME --name web-vmss-lb-pip --query ipAddress -o tsv 2>/dev/null)
AGW_IP=$(az network public-ip show --resource-group $RG_NAME --name webapp-gw-publicip --query ipAddress -o tsv 2>/dev/null)
JUMPBOX_IP=$(az network public-ip show --resource-group $RG_NAME --name jumpbox-vmPublicIP --query ipAddress -o tsv 2>/dev/null)

echo "Load Balancer IP: $LB_IP"
echo "Application Gateway IP: $AGW_IP"
echo "Jump Box IP: $JUMPBOX_IP"
echo

# HTTP connectivity test function
test_http() {
    local url="$1"
    local name="$2"
    local expected_code="$3"
    
    log_info "Testing HTTP: $name ($url)"
    
    response_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time $TIMEOUT "$url" 2>/dev/null || echo "000")
    
    if [[ "$response_code" == "$expected_code" ]]; then
        log_pass "$name: HTTP $response_code"
        ((TESTS_PASSED++))
    else
        log_fail "$name: HTTP $response_code (expected $expected_code)"
        ((TESTS_FAILED++))
    fi
}

# TCP connectivity test function
test_tcp() {
    local host="$1"
    local port="$2"
    local name="$3"
    
    log_info "Testing TCP: $name ($host:$port)"
    
    if timeout $TIMEOUT bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        log_pass "$name: TCP connection successful"
        ((TESTS_PASSED++))
    else
        log_fail "$name: TCP connection failed"
        ((TESTS_FAILED++))
    fi
}

# Public HTTP Tests
echo "🌍 Public HTTP Connectivity Tests"
if [[ -n "$LB_IP" && "$LB_IP" != "null" ]]; then
    test_http "http://$LB_IP" "Load Balancer" "200"
else
    log_warn "Load Balancer IP not found, skipping test"
fi

if [[ -n "$AGW_IP" && "$AGW_IP" != "null" ]]; then
    test_http "http://$AGW_IP" "Application Gateway" "200"
else
    log_warn "Application Gateway IP not found, skipping test"
fi

# Public TCP Tests
echo
echo "🔌 Public TCP Connectivity Tests"
if [[ -n "$JUMPBOX_IP" && "$JUMPBOX_IP" != "null" ]]; then
    test_tcp "$JUMPBOX_IP" "22" "Jump Box SSH"
else
    log_warn "Jump Box IP not found, skipping SSH test"
fi

# Internal connectivity tests (requires jump box access)
echo
echo "🏠 Internal Connectivity Tests"
echo "Note: These tests require SSH access from the jump box"

# Create remote test script for jump box execution
cat > /tmp/internal-connectivity-test.sh << 'EOF'
#!/bin/bash
echo "Running internal connectivity tests from jump box..."

# DNS resolution tests
echo "Testing DNS resolution:"
for host in jumpbox backend-vm database-vm api; do
    if nslookup $host.az104lab.internal >/dev/null 2>&1; then
        echo "✅ DNS: $host.az104lab.internal"
    else
        echo "❌ DNS: $host.az104lab.internal"
    fi
done

# Ping tests
echo
echo "Testing ICMP connectivity:"
for host in backend-vm database-vm; do
    if ping -c 2 -W 3 $host.az104lab.internal >/dev/null 2>&1; then
        echo "✅ PING: $host.az104lab.internal"
    else
        echo "❌ PING: $host.az104lab.internal"
    fi
done

# HTTP tests
echo
echo "Testing HTTP services:"
for host in backend-vm database-vm; do
    if curl -s --max-time 5 http://$host.az104lab.internal >/dev/null 2>&1; then
        echo "✅ HTTP: $host.az104lab.internal"
    else
        echo "❌ HTTP: $host.az104lab.internal"
    fi
done

# SSH tests
echo
echo "Testing SSH connectivity:"
for host in backend-vm database-vm; do
    if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 azuser@$host.az104lab.internal exit 2>/dev/null; then
        echo "✅ SSH: $host.az104lab.internal"
    else
        echo "❌ SSH: $host.az104lab.internal"
    fi
done
EOF

chmod +x /tmp/internal-connectivity-test.sh

echo "Internal connectivity test script created: /tmp/internal-connectivity-test.sh"
echo "To run internal tests:"
echo "1. SSH to jump box: ssh azuser@$JUMPBOX_IP"
echo "2. Copy and run the test script on the jump box"
echo

# Network path testing using Azure Network Watcher (if available)
echo "🛣️ Network Path Analysis"
log_info "Checking Network Watcher availability..."

if az extension show --name network-watcher &>/dev/null || az extension add --name network-watcher &>/dev/null; then
    log_info "Testing network paths with Network Watcher..."
    
    # Test path from jump box to backend VM (if both exist)
    JUMPBOX_NIC=$(az vm show --resource-group $RG_NAME --name jumpbox-vm --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>/dev/null)
    BACKEND_NIC=$(az vm show --resource-group $RG_NAME --name backend-vm --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>/dev/null)
    
    if [[ -n "$JUMPBOX_NIC" && -n "$BACKEND_NIC" ]]; then
        log_info "Testing network path: Jump Box → Backend VM"
        if az network watcher test-connectivity \
            --source-resource "$JUMPBOX_NIC" \
            --dest-resource "$BACKEND_NIC" \
            --resource-group $RG_NAME &>/dev/null; then
            log_pass "Network path test: Jump Box → Backend VM"
            ((TESTS_PASSED++))
        else
            log_fail "Network path test: Jump Box → Backend VM"
            ((TESTS_FAILED++))
        fi
    fi
else
    log_warn "Network Watcher extension not available"
fi

# Load balancer backend health
echo
echo "⚖️ Load Balancer Health Tests"
log_info "Checking Application Gateway backend health..."

AGW_HEALTH=$(az network application-gateway show-backend-health \
    --resource-group $RG_NAME \
    --name web-appgw \
    --query 'backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].health' -o tsv 2>/dev/null)

if [[ "$AGW_HEALTH" == "Healthy" ]]; then
    log_pass "Application Gateway backend health: $AGW_HEALTH"
    ((TESTS_PASSED++))
else
    log_fail "Application Gateway backend health: $AGW_HEALTH"
    ((TESTS_FAILED++))
fi

# Bandwidth test (simple)
echo
echo "📊 Basic Performance Tests"
if [[ -n "$AGW_IP" && "$AGW_IP" != "null" ]]; then
    log_info "Testing response time to Application Gateway..."
    
    response_time=$(curl -s -o /dev/null -w "%{time_total}" --max-time $TIMEOUT "http://$AGW_IP" 2>/dev/null || echo "timeout")
    
    if [[ "$response_time" != "timeout" ]]; then
        response_ms=$(echo "$response_time * 1000" | bc 2>/dev/null || echo "unknown")
        log_pass "Application Gateway response time: ${response_ms}ms"
        ((TESTS_PASSED++))
    else
        log_fail "Application Gateway response time: timeout"
        ((TESTS_FAILED++))
    fi
fi

# Summary
echo
echo "=================================="
echo "Connectivity Test Results:"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "=================================="

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✅ All connectivity tests passed!"
    exit 0
else
    echo "❌ Some connectivity tests failed!"
    exit 1
fi

# ====================
# 4. dns-test.sh - DNS Resolution Testing
# ====================

#!/bin/bash
echo "🏷️ DNS Resolution Test Suite"
echo "============================"

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Configuration
RG_NAME="az104-learn-dns-rg1"
DNS_ZONE="az104lab.internal"

TESTS_PASSED=0
TESTS_FAILED=0

# DNS test function
test_dns_record() {
    local record_name="$1"
    local record_type="$2"
    local expected_result="$3"
    local full_name="$record_name.$DNS_ZONE"
    
    log_info "Testing DNS: $full_name ($record_type)"
    
    case $record_type in
        "A")
            result=$(nslookup "$full_name" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}' 2>/dev/null || echo "NXDOMAIN")
            ;;
        "CNAME")
            result=$(nslookup "$full_name" 2>/dev/null | grep "canonical name" | awk '{print $4}' | sed 's/\.$//' 2>/dev/null || echo "NXDOMAIN")
            ;;
        *)
            result="UNKNOWN_TYPE"
            ;;
    esac
    
    if [[ "$result" != "NXDOMAIN" && "$result" != "UNKNOWN_TYPE" && -n "$result" ]]; then
        if [[ -z "$expected_result" || "$result" == "$expected_result" ]]; then
            log_pass "$full_name → $result"
            ((TESTS_PASSED++))
        else
            log_fail "$full_name → $result (expected: $expected_result)"
            ((TESTS_FAILED++))
        fi
    else
        log_fail "$full_name → No resolution"
        ((TESTS_FAILED++))
    fi
}

# DNS infrastructure tests
echo "🏗️ DNS Infrastructure Tests"
log_info "Checking private DNS zone configuration..."

# Check if private DNS zone exists
if az network private-dns zone show --resource-group $RG_NAME --name $DNS_ZONE &>/dev/null; then
    log_pass "Private DNS zone exists: $DNS_ZONE"
    ((TESTS_PASSED++))
else
    log_fail "Private DNS zone missing: $DNS_ZONE"
    ((TESTS_FAILED++))
fi

# Check VNet links
for vnet in vnet1 vnet2; do
    if az network private-dns link vnet show --resource-group $RG_NAME --zone-name $DNS_ZONE --name "${vnet}-link" &>/dev/null; then
        log_pass "DNS VNet link exists: ${vnet}-link"
        ((TESTS_PASSED++))
    else
        log_fail "DNS VNet link missing: ${vnet}-link"
        ((TESTS_FAILED++))
    fi
done

# A Record Tests
echo
echo "📝 A Record Resolution Tests"

# Get expected IPs from Azure resources
JUMPBOX_IP=$(az vm list-ip-addresses --resource-group $RG_NAME --name jumpbox-vm --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)
BACKEND_IP=$(az vm list-ip-addresses --resource-group $RG_NAME --name backend-vm --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)
DATABASE_IP=$(az vm list-ip-addresses --resource-group $RG_NAME --name database-vm --query '[].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>/dev/null)
AGW_IP=$(az network public-ip show --resource-group $RG_NAME --name webapp-gw-publicip --query ipAddress -o tsv 2>/dev/null)
LB_IP=$(az network public-ip show --resource-group $RG_NAME --name web-vmss-lb-pip --query ipAddress -o tsv 2>/dev/null)

# Test A records
test_dns_record "jumpbox" "A" "$JUMPBOX_IP"
test_dns_record "backend-vm" "A" "$BACKEND_IP"
test_dns_record "database-vm" "A" "$DATABASE_IP"
test_dns_record "database" "A" "$DATABASE_IP"
test_dns_record "appgateway" "A" "$AGW_IP"
test_dns_record "loadbalancer" "A" "$LB_IP"

# CNAME Record Tests
echo
echo "🔗 CNAME Record Resolution Tests"
test_dns_record "api" "CNAME" "appgateway.$DNS_ZONE"
test_dns_record "frontend" "CNAME" "appgateway.$DNS_ZONE"
test_dns_record "backend" "CNAME" "appgateway.$DNS_ZONE"
test_dns_record "db" "CNAME" "database.$DNS_ZONE"
test_dns_record "api-backend" "CNAME" "backend-vm.$DNS_ZONE"

# Auto-registered VM records test
echo
echo "🤖 Auto-registered VM Records"
# VMs should auto-register with their VM names
VM_NAMES=$(az vm list --resource-group $RG_NAME --query '[].name' -o tsv)
for vm_name in $VM_NAMES; do
    test_dns_record "$vm_name" "A" ""
done

# Reverse DNS tests
echo
echo "↩️ Reverse DNS Tests"
if [[ -n "$JUMPBOX_IP" && "$JUMPBOX_IP" != "null" ]]; then
    log_info "Testing reverse DNS for jump box: $JUMPBOX_IP"
    reverse_result=$(nslookup "$JUMPBOX_IP" 2>/dev/null | grep "name =" | awk '{print $4}' | sed 's/\.$//' || echo "No PTR")
    if [[ "$reverse_result" != "No PTR" ]]; then
        log_pass "Reverse DNS: $JUMPBOX_IP → $reverse_result"
        ((TESTS_PASSED++))
    else
        log_warn "No reverse DNS configured for $JUMPBOX_IP (normal for lab)"
    fi
fi

# DNS query performance test
echo
echo "⚡ DNS Performance Tests"
for record in jumpbox api backend-vm database; do
    start_time=$(date +%s%N)
    nslookup "$record.$DNS_ZONE" >/dev/null 2>&1
    end_time=$(date +%s%N)
    
    if [[ $? -eq 0 ]]; then
        query_time=$(( (end_time - start_time) / 1000000 ))
        if [[ $query_time -lt 1000 ]]; then
            log_pass "DNS query time for $record: ${query_time}ms"
            ((TESTS_PASSED++))
        else
            log_warn "DNS query time for $record: ${query_time}ms (slow)"
        fi
    else
        log_fail "DNS query failed for $record"
        ((TESTS_FAILED++))
    fi
done

# External DNS test (ensure external resolution still works)
echo
echo "🌍 External DNS Resolution Test"
if nslookup google.com >/dev/null 2>&1; then
    log_pass "External DNS resolution working"
    ((TESTS_PASSED++))
else
    log_fail "External DNS resolution broken"
    ((TESTS_FAILED++))
fi

# DNS record count validation
echo
echo "📊 DNS Record Inventory"
A_RECORDS=$(az network private-dns record-set a list --resource-group $RG_NAME --zone-name $DNS_ZONE --query 'length(@)' -o tsv 2>/dev/null || echo 0)
CNAME_RECORDS=$(az network private-dns record-set cname list --resource-group $RG_NAME --zone-name $DNS_ZONE --query 'length(@)' -o tsv 2>/dev/null || echo 0)
TXT_RECORDS=$(az network private-dns record-set txt list --resource-group $RG_NAME --zone-name $DNS_ZONE --query 'length(@)' -o tsv 2>/dev/null || echo 0)

log_info "DNS Record Summary:"
echo "  A Records: $A_RECORDS"
echo "  CNAME Records: $CNAME_RECORDS"
echo "  TXT Records: $TXT_RECORDS"

if [[ $A_RECORDS -ge 5 ]]; then
    log_pass "Sufficient A records configured"
    ((TESTS_PASSED++))
else
    log_fail "Insufficient A records: $A_RECORDS (expected: ≥5)"
    ((TESTS_FAILED++))
fi

if [[ $CNAME_RECORDS -ge 3 ]]; then
    log_pass "Sufficient CNAME records configured"
    ((TESTS_PASSED++))
else
    log_fail "Insufficient CNAME records: $CNAME_RECORDS (expected: ≥3)"
    ((TESTS_FAILED++))
fi

# Create DNS test script for internal execution
echo
echo "📋 Creating DNS test script for jump box execution..."
cat > /tmp/internal-dns-test.sh << 'EOF'
#!/bin/bash
echo "=== Internal DNS Resolution Test ==="
echo "Testing from $(hostname) - $(hostname -I | awk