// ===================================
// Azure Multi-VNet Enterprise Architecture
// AZ-104 Learning Lab - Complete Infrastructure
// ===================================

@description('Location for all resources')
param location string = resourceGroup().location

@description('Admin username for VMs')
param adminUsername string = 'azuser'

@description('SSH public key for VM access')
param sshPublicKey string

@description('Your current public IP for jump box access')
param yourPublicIP string

@description('Environment tag')
param environment string = 'Learning'

@description('Project tag')
param project string = 'AZ104'

// ===================================
// VARIABLES
// ===================================

// Network Configuration
var vnet1Name = 'vnet1'
var vnet1AddressPrefix = '10.0.0.0/16'
var vnet1Subnet1Name = 'subnet1'
var vnet1Subnet1Prefix = '10.0.1.0/24'
var vnet1Subnet2Name = 'subnet2'  
var vnet1Subnet2Prefix = '10.0.2.0/24'
var vnet1AppGwSubnetName = 'eca-appgwsubnet'
var vnet1AppGwSubnetPrefix = '10.0.3.0/24'

var vnet2Name = 'vnet2'
var vnet2AddressPrefix = '10.1.0.0/16'
var vnet2BackendSubnetName = 'backend-subnet'
var vnet2BackendSubnetPrefix = '10.1.1.0/24'
var vnet2DatabaseSubnetName = 'database-subnet'
var vnet2DatabaseSubnetPrefix = '10.1.2.0/24'

// VM Configuration
var jumpboxVmName = 'jumpbox-vm'
var backendVmName = 'backend-vm'
var databaseVmName = 'database-vm'
var vmssName = 'web-vmss'

// Load Balancer Configuration
var lbName = 'web-vmss-lb'
var lbPublicIpName = 'web-vmss-lb-pip'

// Application Gateway Configuration
var appGwName = 'web-appgw'
var appGwPublicIpName = 'webapp-gw-publicip'
var wafPolicyName = 'web-appgw-waf-policy'

// NSG Configuration
var jumpboxNsgName = 'jumpbox-nsg'
var vmssNsgName = 'web-vmss-nsg'
var vnet2NsgName = 'vnet2-nsg'

// DNS Configuration
var privateDnsZoneName = 'az104lab.internal'

// Common Tags
var commonTags = {
  Environment: environment
  Project: project
  Purpose: 'AZ104-Learning'
}

// ===================================
// NETWORK SECURITY GROUPS
// ===================================

// Jump Box NSG
resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: jumpboxNsgName
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowSSHFromMyIP'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '${yourPublicIP}/32'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
          description: 'Allow SSH from current IP'
        }
      }
      {
        name: 'DenyAllSSH'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 4000
          direction: 'Inbound'
          description: 'Deny all other SSH access'
        }
      }
    ]
  }
}

// ===================================
// VIRTUAL MACHINE SCALE SET
// ===================================

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: vmssName
  location: location
  tags: union(commonTags, { Role: 'WebServer' })
  sku: {
    name: 'Standard_B1s'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    upgradePolicy: {
      mode: 'Automatic'
    }
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
      }
      osProfile: {
        computerNamePrefix: vmssName
        adminUsername: adminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
        customData: base64('''#cloud-config
package_update: true
package_upgrade: true
packages:
  - nginx
  - htop
  - curl

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
                  <li>DONE: Application Gateway (Layer 7 Load Balancing)</li>
                  <li>DONE: VNet Peering (Cross-VNet Communication)</li>
                  <li>DONE: Private DNS (Service Discovery)</li>
              </ul>
          </div>
          <script>
              document.getElementById('hostname').textContent = window.location.hostname;
              document.getElementById('ip').textContent = window.location.host;
              document.getElementById('loadtime').textContent = new Date().toLocaleString();
          </script>
      </body>
      </html>

runcmd:
  - systemctl start nginx
  - systemctl enable nginx
  - ufw allow 'Nginx Full'
  - ufw allow ssh
  - echo "Web server setup completed at $(date)" >> /var/log/setup.log
''')
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: '${vmssName}Nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: '${vmssName}IPConfig'
                  properties: {
                    subnet: {
                      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1Name, vnet1Subnet1Name)
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, '${lbName}-backend')
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    vnet1
    loadBalancer
  ]
}

// ===================================
// AUTO-SCALING
// ===================================

resource vmssAutoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: '${vmssName}-autoscale'
  location: location
  tags: commonTags
  properties: {
    profiles: [
      {
        name: 'default'
        capacity: {
          minimum: '1'
          maximum: '10'
          default: '1'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 80
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 20
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
    enabled: true
    targetResourceUri: vmss.id
  }
}

// ===================================
// BACKEND VMs (VNet2)
// ===================================

// Backend VM
resource backendNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${backendVmName}-nic'
  location: location
  tags: commonTags
  properties: {
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet2Name, vnet2BackendSubnetName)
          }
        }
      }
    ]
  }
  dependsOn: [
    vnet2
  ]
}

resource backendVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: backendVmName
  location: location
  tags: union(commonTags, { Role: 'Backend', Tier: 'Backend' })
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: backendVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      customData: base64('''#cloud-config
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
''')
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: backendNic.id
        }
      ]
    }
  }
}

// Database VM
resource databaseNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${databaseVmName}-nic'
  location: location
  tags: commonTags
  properties: {
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet2Name, vnet2DatabaseSubnetName)
          }
        }
      }
    ]
  }
  dependsOn: [
    vnet2
  ]
}

resource databaseVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: databaseVmName
  location: location
  tags: union(commonTags, { Role: 'Database', Tier: 'Database' })
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: databaseVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      customData: base64('''#cloud-config
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
''')
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: databaseNic.id
        }
      ]
    }
  }
}

// ===================================
// PRIVATE DNS ZONE
// ===================================

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: commonTags
}

// VNet Links
resource vnet1DnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'vnet1-link'
  location: 'global'
  properties: {
    registrationEnabled: true
    virtualNetwork: {
      id: vnet1.id
    }
  }
}

resource vnet2DnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'vnet2-link'
  location: 'global'
  properties: {
    registrationEnabled: true
    virtualNetwork: {
      id: vnet2.id
    }
  }
}

// DNS A Records
resource jumpboxDnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'jumpbox'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: jumpboxNic.properties.ipConfigurations[0].properties.privateIPAddress
      }
    ]
  }
  dependsOn: [
    jumpboxNic
  ]
}

resource appgatewayDnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'appgateway'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: appGwPublicIp.properties.ipAddress
      }
    ]
  }
}

resource loadbalancerDnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'loadbalancer'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: lbPublicIp.properties.ipAddress
      }
    ]
  }
}

resource databaseDnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'database'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: databaseNic.properties.ipConfigurations[0].properties.privateIPAddress
      }
    ]
  }
  dependsOn: [
    databaseNic
  ]
}

// DNS CNAME Records
resource apiDnsCname 'Microsoft.Network/privateDnsZones/CNAME@2020-06-01' = {
  parent: privateDnsZone
  name: 'api'
  properties: {
    ttl: 3600
    cnameRecord: {
      cname: 'appgateway.${privateDnsZoneName}'
    }
  }
}

resource frontendDnsCname 'Microsoft.Network/privateDnsZones/CNAME@2020-06-01' = {
  parent: privateDnsZone
  name: 'frontend'
  properties: {
    ttl: 3600
    cnameRecord: {
      cname: 'appgateway.${privateDnsZoneName}'
    }
  }
}

resource backendDnsCname 'Microsoft.Network/privateDnsZones/CNAME@2020-06-01' = {
  parent: privateDnsZone
  name: 'backend'
  properties: {
    ttl: 3600
    cnameRecord: {
      cname: 'appgateway.${privateDnsZoneName}'
    }
  }
}

resource dbDnsCname 'Microsoft.Network/privateDnsZones/CNAME@2020-06-01' = {
  parent: privateDnsZone
  name: 'db'
  properties: {
    ttl: 3600
    cnameRecord: {
      cname: 'database.${privateDnsZoneName}'
    }
  }
}

resource apiBackendDnsCname 'Microsoft.Network/privateDnsZones/CNAME@2020-06-01' = {
  parent: privateDnsZone
  name: 'api-backend'
  properties: {
    ttl: 3600
    cnameRecord: {
      cname: 'backend-vm.${privateDnsZoneName}'
    }
  }
}

// Documentation TXT Records
resource labInfoTxtRecord 'Microsoft.Network/privateDnsZones/TXT@2020-06-01' = {
  parent: privateDnsZone
  name: '_lab-info'
  properties: {
    ttl: 3600
    txtRecords: [
      {
        value: ['AZ-104 Learning Lab - Multi-VNet Architecture']
      }
    ]
  }
}

resource architectureTxtRecord 'Microsoft.Network/privateDnsZones/TXT@2020-06-01' = {
  parent: privateDnsZone
  name: '_architecture'
  properties: {
    ttl: 3600
    txtRecords: [
      {
        value: ['Jump Box + VMSS + Load Balancer + Application Gateway + VNet Peering + Private DNS']
      }
    ]
  }
}

// ===================================
// OUTPUTS
// ===================================

@description('Resource Group Name')
output resourceGroupName string = resourceGroup().name

@description('Jump Box Public IP')
output jumpboxPublicIP string = jumpboxPublicIp.properties.ipAddress

@description('Load Balancer Public IP')
output loadBalancerPublicIP string = lbPublicIp.properties.ipAddress

@description('Application Gateway Public IP')
output applicationGatewayPublicIP string = appGwPublicIp.properties.ipAddress

@description('Application Gateway FQDN')
output applicationGatewayFQDN string = appGwPublicIp.properties.dnsSettings.fqdn

@description('Private DNS Zone Name')
output privateDnsZoneName string = privateDnsZone.name

@description('VNet1 ID')
output vnet1Id string = vnet1.id

@description('VNet2 ID')
output vnet2Id string = vnet2.id

@description('SSH Connection Command')
output sshConnectionCommand string = 'ssh -i ~/.ssh/your-key ${adminUsername}@${jumpboxPublicIp.properties.ipAddress}'

@description('DNS Test Commands')
output dnsTestCommands array = [
  'nslookup jumpbox.${privateDnsZoneName}'
  'nslookup api.${privateDnsZoneName}'
  'nslookup backend-vm.${privateDnsZoneName}'
  'nslookup database-vm.${privateDnsZoneName}'
]

@description('Web Application URLs')
output webApplicationUrls array = [
  'http://${lbPublicIp.properties.ipAddress}'
  'http://${appGwPublicIp.properties.ipAddress}'
  'http://${appGwPublicIp.properties.dnsSettings.fqdn}'
]

@description('Deployment Summary')
output deploymentSummary object = {
  architecture: 'Multi-VNet Enterprise Architecture'
  components: {
    virtualNetworks: 2
    virtualMachines: '3+ (1 jump box + 1-10 VMSS instances + 2 backend VMs)'
    loadBalancers: 2
    networkSecurityGroups: 3
    publicIpAddresses: 3
    privateDnsZones: 1
    vnetPeering: 'Bidirectional'
    autoScaling: 'CPU-based (1-10 instances)'
    webApplicationFirewall: 'OWASP 3.2'
    serviceDiscovery: 'Private DNS'
  }
  testUrls: {
    loadBalancer: 'http://${lbPublicIp.properties.ipAddress}'
    applicationGateway: 'http://${appGwPublicIp.properties.ipAddress}'
    jumpBoxSSH: 'ssh ${adminUsername}@${jumpboxPublicIp.properties.ipAddress}'
  }
  dnsRecords: {
    jumpbox: 'jumpbox.${privateDnsZoneName}'
    api: 'api.${privateDnsZoneName}'
    frontend: 'frontend.${privateDnsZoneName}'
    backend: 'backend-vm.${privateDnsZoneName}'
    database: 'database-vm.${privateDnsZoneName}'
  }
}
}

// VMSS NSG
resource vmssNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: vmssNsgName
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowHTTP'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
          description: 'Allow HTTP traffic'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1010
          direction: 'Inbound'
          description: 'Allow HTTPS traffic'
        }
      }
      {
        name: 'AllowSSHFromVNet'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 2000
          direction: 'Inbound'
          description: 'Allow SSH from VNet'
        }
      }
    ]
  }
}

// VNet2 NSG
resource vnet2Nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: vnet2NsgName
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowSSHFromVNet1'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: vnet1AddressPrefix
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
          description: 'Allow SSH from VNet1'
        }
      }
      {
        name: 'AllowHTTPFromVNets'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: ['80', '443']
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1010
          direction: 'Inbound'
          description: 'Allow HTTP/HTTPS from VNets'
        }
      }
      {
        name: 'AllowDatabaseFromVNet2'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: ['3306', '5432']
          sourceAddressPrefix: vnet2AddressPrefix
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1020
          direction: 'Inbound'
          description: 'Allow database connections from VNet2'
        }
      }
    ]
  }
}

// ===================================
// VIRTUAL NETWORKS
// ===================================

// VNet1 - Frontend/Web Tier
resource vnet1 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnet1Name
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [vnet1AddressPrefix]
    }
    subnets: [
      {
        name: vnet1Subnet1Name
        properties: {
          addressPrefix: vnet1Subnet1Prefix
          networkSecurityGroup: {
            id: vmssNsg.id
          }
        }
      }
      {
        name: vnet1Subnet2Name
        properties: {
          addressPrefix: vnet1Subnet2Prefix
          networkSecurityGroup: {
            id: jumpboxNsg.id
          }
        }
      }
      {
        name: vnet1AppGwSubnetName
        properties: {
          addressPrefix: vnet1AppGwSubnetPrefix
        }
      }
    ]
  }
}

// VNet2 - Backend Tier
resource vnet2 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnet2Name
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [vnet2AddressPrefix]
    }
    subnets: [
      {
        name: vnet2BackendSubnetName
        properties: {
          addressPrefix: vnet2BackendSubnetPrefix
          networkSecurityGroup: {
            id: vnet2Nsg.id
          }
        }
      }
      {
        name: vnet2DatabaseSubnetName
        properties: {
          addressPrefix: vnet2DatabaseSubnetPrefix
          networkSecurityGroup: {
            id: vnet2Nsg.id
          }
        }
      }
    ]
  }
}

// ===================================
// VNET PEERING
// ===================================

resource vnet1ToVnet2Peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnet1
  name: 'vnet1-to-vnet2'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: vnet2.id
    }
  }
}

resource vnet2ToVnet1Peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnet2
  name: 'vnet2-to-vnet1'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: vnet1.id
    }
  }
}

// ===================================
// PUBLIC IP ADDRESSES
// ===================================

// Jump Box Public IP
resource jumpboxPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'jumpbox-vmPublicIP'
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Load Balancer Public IP
resource lbPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: lbPublicIpName
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Application Gateway Public IP
resource appGwPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: appGwPublicIpName
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
  }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'az104-appgw-${uniqueString(resourceGroup().id)}'
    }
  }
}

// ===================================
// LOAD BALANCER
// ===================================

resource loadBalancer 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: lbName
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: '${lbName}-frontend'
        properties: {
          publicIPAddress: {
            id: lbPublicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: '${lbName}-backend'
      }
    ]
    probes: [
      {
        name: 'http-probe'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/'
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'http-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, '${lbName}-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, '${lbName}-backend')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'http-probe')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
        }
      }
    ]
  }
}

// ===================================
// WAF POLICY
// ===================================

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-09-01' = {
  name: wafPolicyName
  location: location
  tags: commonTags
  properties: {
    policySettings: {
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
      state: 'Enabled'
      mode: 'Prevention'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

// ===================================
// APPLICATION GATEWAY
// ===================================

resource applicationGateway 'Microsoft.Network/applicationGateways@2023-09-01' = {
  name: appGwName
  location: location
  tags: commonTags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1Name, vnet1AppGwSubnetName)
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIp'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: appGwPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'appGatewayBackendPool'
        properties: {}
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'appGatewayBackendHttpSettings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: false
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'appGatewayHttpListener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGwPublicFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_80')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule1'
        properties: {
          priority: 1000
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'appGatewayHttpListener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'appGatewayBackendPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'appGatewayBackendHttpSettings')
          }
        }
      }
    ]
    enableHttp2: false
    firewallPolicy: {
      id: wafPolicy.id
    }
  }
  dependsOn: [
    vnet1
  ]
}

// ===================================
// JUMP BOX VM
// ===================================

resource jumpboxNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${jumpboxVmName}-nic'
  location: location
  tags: commonTags
  properties: {
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: jumpboxPublicIp.id
          }
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1Name, vnet1Subnet2Name)
          }
        }
      }
    ]
  }
  dependsOn: [
    vnet1
  ]
}

resource jumpboxVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: jumpboxVmName
  location: location
  tags: union(commonTags, { Role: 'JumpBox' })
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: jumpboxVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jumpboxNic.id
        }
      ]
    }
  }
