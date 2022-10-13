terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.21.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source = "azure/azapi"
      version = "=0.5.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

locals {
  func_name = "aksworkid${random_string.unique.result}"
  cluster_name = local.func_name
  loc_for_naming = lower(replace(var.location, " ", ""))
  gh_repo = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-EUS"
  resource_group_name = "DefaultResourceGroup-EUS"
} 

data "azurerm_network_security_group" "basic" {
    name                = "basic"
    resource_group_name = "rg-network-eastus"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

data "azurerm_key_vault" "kv" {
  name                = var.kv_name
  resource_group_name = replace(var.kv_name, "kv-", "rg-")
}

data "azurerm_key_vault_secret" "secret" {
  name         = "generic-public-key"
  key_vault_id = data.azurerm_key_vault.kv.id
  
}

resource "azurerm_virtual_network" "default" {
  name                = "${local.cluster_name}-vnet-eastus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = local.tags
}


resource "azurerm_subnet" "default" {
  name                 = "default-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "cluster" {
  name                 = "${local.cluster_name}-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.0.2.0/23"]

}


resource "azurerm_network_interface" "example" {
  name                = "example-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.default.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }

}

resource "azurerm_public_ip" "pip" {
  name                = "proxy-public-ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"

}


data "template_file" "vm-cloud-init" {
  template = file("${path.module}/install-tinyproxy.sh")
}

resource "azurerm_linux_virtual_machine" "example" {
  name                  = "vm-${local.cluster_name}-proxy"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_B1s"
  custom_data           = base64encode(data.template_file.vm-cloud-init.rendered)
  
  network_interface_ids = [
    azurerm_network_interface.example.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  admin_username = "azureuser"
  admin_ssh_key {
    public_key = data.azurerm_key_vault_secret.secret.value
    username   = "azureuser"
  }
}

data "azurerm_kubernetes_service_versions" "current" {
  location = azurerm_resource_group.rg.location
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                    = local.cluster_name
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  dns_prefix              = local.cluster_name
  kubernetes_version      = data.azurerm_kubernetes_service_versions.current.latest_version
  private_cluster_enabled = false
  default_node_pool {
    name            = "default"
    node_count      = 1
    vm_size         = "Standard_B2ms"
    os_disk_size_gb = "128"
    vnet_subnet_id  = azurerm_subnet.cluster.id


  }
  network_profile {
    network_plugin     = "azure"
    network_policy     = "azure"
    service_cidr       = "10.255.252.0/22"
    dns_service_ip     = "10.255.252.10"
    docker_bridge_cidr = "172.17.0.1/16"
  }

  role_based_access_control_enabled = true

  identity {
    type = "SystemAssigned"
  }
  
  oidc_issuer_enabled = true
  # oms_agent {
  #   log_analytics_workspace_id = data.azurerm_log_analytics_workspace.default.id
  # }

  tags = local.tags

}

resource "azurerm_kubernetes_cluster" "aksproxy" {
  name                    = "${local.cluster_name}proxy"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  dns_prefix              = local.cluster_name
  kubernetes_version      = data.azurerm_kubernetes_service_versions.current.latest_version
  private_cluster_enabled = false
  default_node_pool {
    name            = "default"
    node_count      = 1
    vm_size         = "Standard_B2ms"
    os_disk_size_gb = "128"
    vnet_subnet_id  = azurerm_subnet.cluster.id


  }
  network_profile {
    network_plugin     = "azure"
    network_policy     = "azure"
    service_cidr       = "10.255.252.0/22"
    dns_service_ip     = "10.255.252.10"
    docker_bridge_cidr = "172.17.0.1/16"
  }

  role_based_access_control_enabled = true

  identity {
    type = "SystemAssigned"
  }
  
  http_proxy_config {
    http_proxy = "http://${azurerm_network_interface.example.private_ip_address}:8888"    
    https_proxy = "http://${azurerm_network_interface.example.private_ip_address}:8888"
    no_proxy = [
     "cluster.local",
     "default"
    ]
  }
  oidc_issuer_enabled = true
  # oms_agent {
  #   log_analytics_workspace_id = data.azurerm_log_analytics_workspace.default.id
  # }

  tags = local.tags
  lifecycle {
    ignore_changes = [
      http_proxy_config.0.no_proxy
    ]
  }
}

resource "azapi_resource_action" "enable_workloadid" {
  type        = "Microsoft.ContainerService/managedClusters@2022-03-02-preview"
  resource_id = azurerm_kubernetes_cluster.aks.id
  method      = "PUT"
  
  body = jsonencode({
    location = azurerm_resource_group.rg.location
    properties = {
      "securityProfile" = {
        "workloadIdentity" = {
          "enabled" = true
        }
      }
    }
  })
  response_export_values = ["*"]
}

resource "azapi_resource_action" "update" {
  type        = "Microsoft.ContainerService/managedClusters@2022-03-02-preview"
  resource_id = azurerm_kubernetes_cluster.aksproxy.id
  method      = "PUT"
  
  body = jsonencode({
    location = azurerm_resource_group.rg.location
    properties = {
      "securityProfile" = {
        "workloadIdentity" = {
          "enabled" = true
        }
      }
    }
  })
  response_export_values = ["*"]
}

# resource "azapi_resource_action" "enable-az-mon" {
#   type        = "Microsoft.ContainerService/managedClusters@2022-09-02-preview"
#   resource_id = azurerm_kubernetes_cluster.aks.id
#   method      = "PUT"
  
#   body = jsonencode({
#     location = azurerm_resource_group.rg.location
#     properties = {
#           "azureMonitorProfile": {
#             "metrics": {
#                 "enabled": true,
#                 "kubeStateMetrics": {
#                     "metricLabelsAllowlist": "",
#                     "metricAnnotationsAllowList": ""
#                 }
#             }
#         }
#     }
#   })
#   response_export_values = ["*"]
# }

resource "azurerm_role_assignment" "network" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity.0.principal_id
}

resource "azurerm_role_assignment" "networkproxy" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aksproxy.identity.0.principal_id
}

# resource "azurerm_role_assignment" "fast_metrics" {
#   scope                = azurerm_kubernetes_cluster.aks.id
#   role_definition_name = "Monitoring Metrics Publisher"
#   principal_id         = azurerm_kubernetes_cluster.aks.oms_agent[0].oms_agent_identity[0].object_id
# }

# resource "azurerm_role_assignment" "fast_metricsproxy" {
#   scope                = azurerm_kubernetes_cluster.aks.id
#   role_definition_name = "Monitoring Metrics Publisher"
#   principal_id         = azurerm_kubernetes_cluster.aksproxy.oms_agent[0].oms_agent_identity[0].object_id
# }

resource "azurerm_user_assigned_identity" "fic" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  name = "uai-fic-${local.cluster_name}"
}

# resource "azapi_resource" "fic" {
#   depends_on = [
#     azurerm_kubernetes_cluster.aks
#   ]
#   type = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2022-01-31-preview"
#   name      = "azapific"
#   parent_id = azurerm_user_assigned_identity.fic.id

#   body = jsonencode({
#     properties = {
#       audiences = [
#         "api://AzureADTokenExchange"
#       ]
#       issuer = azurerm_kubernetes_cluster.aks.oidc_issuer_url 
#       subject = "system:serviceaccount:default:${azurerm_user_assigned_identity.fic.name}"
#     }
#   })
# }

# resource "azapi_resource" "ficproxy" {
#   depends_on = [
#     azurerm_kubernetes_cluster.aks
#   ]
#   type = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2022-01-31-preview"
#   name      = "azapificproxy"
#   parent_id = azurerm_user_assigned_identity.fic.id

#   body = jsonencode({
#     properties = {
#       audiences = [
#         "api://AzureADTokenExchange"
#       ]
#       issuer = azurerm_kubernetes_cluster.aksproxy.oidc_issuer_url 
#       subject = "system:serviceaccount:default:${azurerm_user_assigned_identity.fic.name}"
#     }
#   })
# }

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  
}

resource "azurerm_key_vault_access_policy" "sp" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = data.azurerm_client_config.current.object_id
  
  key_permissions = [
    "Create",
    "Get",
    "Purge",
    "Recover",
    "Delete"
  ]

  secret_permissions = [
    "Set",
    "Purge",
    "Get",
    "List",
    "Delete"
  ]

  certificate_permissions = [
    "Purge"
  ]

  storage_permissions = [
    "Purge"
  ]
  
}


resource "azurerm_key_vault_access_policy" "uai" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = azurerm_user_assigned_identity.fic.principal_id
  
  key_permissions = [
    "Get",
  ]

  secret_permissions = [
    "Get",
    "List"
  ]
  
}

resource "azurerm_key_vault_secret" "helloworld" {
  depends_on = [
    azurerm_key_vault_access_policy.sp
  ]
  name         = "hello"
  value        = "world"
  key_vault_id = azurerm_key_vault.kv.id
  tags         = local.tags
}
