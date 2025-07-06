locals {
  tags = merge(
    {
      "kubernetes.io_cluster.${var.cluster_id}" = "owned"
    },
    var.azure_extra_tags,
  )
  description = "Created By OpenShift Installer"
  # At this time min_tls_version is only supported in the Public Cloud and US Government Cloud.
  environments_with_min_tls_version = ["public", "usgovernment"]

}

provider "azurerm" {
  features {}
  subscription_id             = var.azure_subscription_id
  client_id                   = var.azure_client_id
  client_secret               = var.azure_client_secret
  client_certificate_password = var.azure_certificate_password
  client_certificate_path     = var.azure_certificate_path
  tenant_id                   = var.azure_tenant_id
  use_msi                     = var.azure_use_msi
  storage_use_azuread         = var.azure_use_msi
  environment                 = var.azure_environment
}

resource "azurerm_resource_group" "main" {
  count = var.azure_resource_group_name == "" ? 1 : 0

  name     = "${var.cluster_id}-rg"
  location = var.azure_region
  tags     = merge(var.azure_extra_tags, var.azure_resource_group_metadata_tags)
}

data "azurerm_resource_group" "main" {
  name = var.azure_resource_group_name == "" ? "${var.cluster_id}-rg" : var.azure_resource_group_name

  depends_on = [azurerm_resource_group.main]
}

data "azurerm_resource_group" "base_domain" {
  name = var.azure_base_domain_resource_group_name
}

data "azurerm_resource_group" "network" {
  count = var.azure_preexisting_network ? 1 : 0

  name = var.azure_network_resource_group_name
}

data "azurerm_key_vault" "keyvault" {
  count = var.azure_keyvault_name != "" ? 1 : 0

  name                = var.azure_keyvault_name
  resource_group_name = var.azure_keyvault_resource_group
}

data "azurerm_key_vault_key" "keyvault_key" {
  count = var.azure_keyvault_name != "" ? 1 : 0

  name         = var.azure_keyvault_key_name
  key_vault_id = data.azurerm_key_vault.keyvault[0].id
}

data "azurerm_user_assigned_identity" "keyvault_identity" {
  count = var.azure_keyvault_name != "" ? 1 : 0

  resource_group_name = var.azure_keyvault_resource_group
  name                = var.azure_user_assigned_identity_key
}

resource "azurerm_storage_account" "cluster" {
  name                             = "cluster${var.random_storage_account_suffix}"
  resource_group_name              = data.azurerm_resource_group.main.name
  location                         = var.azure_region
  account_tier                     = var.azure_keyvault_name != "" ? "Premium" : "Standard"
  account_replication_type         = "LRS"
  min_tls_version                  = contains(local.environments_with_min_tls_version, var.azure_environment) ? "TLS1_2" : null
  allow_nested_items_to_be_public  = var.azure_keyvault_name != "" ? true : false
  tags                             = var.azure_extra_tags
  cross_tenant_replication_enabled = false

  dynamic "customer_managed_key" {
    for_each = var.azure_keyvault_name != "" ? [1] : []
    content {
      key_vault_key_id          = data.azurerm_key_vault_key.keyvault_key[0].id
      user_assigned_identity_id = data.azurerm_user_assigned_identity.keyvault_identity[0].id
    }
  }

  dynamic identity {
    for_each = var.azure_keyvault_name != "" ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [data.azurerm_user_assigned_identity.keyvault_identity[0].id]
    }
  }

  network_rules {
    default_action = "Deny"
    # virtual_network_subnet_ids = [local.master_subnet_id, local.worker_subnet_id]
    bypass = ["AzureServices"]
  }
}

resource "azurerm_private_dns_zone" "private_dns_zone_based" {
  count = var.azure_preexisting_bastion_network ? 1 : 0

  name                = "privatelink-${var.cluster_id}.blob.core.windows.net"
  resource_group_name = var.azure_base_domain_resource_group_name
}
 
resource "azurerm_private_dns_zone" "private_dns_zone" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.azure_network_resource_group_name
}
 
resource "azurerm_private_dns_zone_virtual_network_link" "vnet_link" {
  name                  = "vnet-link"
  resource_group_name   = var.azure_network_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone.name
  virtual_network_id    = local.virtual_network_id
  registration_enabled  = true
}

resource "azurerm_private_dns_zone_virtual_network_link" "bastion_vnet_link" {
  count = var.azure_preexisting_bastion_network ? 1 : 0

  name                  = "bastion-vnet-link"
  resource_group_name   = var.azure_base_domain_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone_based[0].name
  virtual_network_id    = local.bastion_virtual_network_id
  registration_enabled  = true
}

resource "azurerm_private_endpoint" "private_endpoint" {
  name                = "storage-endpoint"
  location            = var.azure_region
  resource_group_name = var.azure_network_resource_group_name
  subnet_id           = local.master_subnet_id
 
  private_service_connection {
    name                           = "storage-endpoint-connection"
    private_connection_resource_id = azurerm_storage_account.cluster.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
 
  private_dns_zone_group {
    name                 = "storage-endpoint-connection"
    private_dns_zone_ids = [azurerm_private_dns_zone.private_dns_zone.id]
  }
 
  depends_on = [azurerm_storage_account.cluster]
}

resource "azurerm_private_endpoint" "bastion_private_endpoint" {
  count = var.azure_preexisting_bastion_network ? 1 : 0

  name                = "bastion-storage-endpoint"
  location            = var.azure_region
  resource_group_name = var.azure_base_domain_resource_group_name
  subnet_id           = local.bastion_subnet_id
 
  private_service_connection {
    name                           = "bastion-storage-endpoint-connection"
    private_connection_resource_id = azurerm_storage_account.cluster.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
 
  private_dns_zone_group {
    name                 = "bastion-storage-endpoint-connection"
    private_dns_zone_ids = [azurerm_private_dns_zone.private_dns_zone_based[0].id]
  }
 
  depends_on = [azurerm_storage_account.cluster]
}

/* 
resource "azurerm_private_dns_a_record" "cluster" {
  name                = "cluster"
  zone_name           = "privatelink.blob.core.windows.net"
  resource_group_name = var.azure_network_resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.private_endpoint.private_service_connection.0.private_ip_address]
}
*/

resource "azurerm_private_dns_a_record" "cluster-bastion" {
  count = var.azure_preexisting_bastion_network ? 1 : 0

  name                = "cluster-bastion"
  zone_name           = "privatelink-${var.cluster_id}.blob.core.windows.net"
  resource_group_name = var.azure_base_domain_resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.private_endpoint.private_service_connection.0.private_ip_address]
}

resource "azurerm_user_assigned_identity" "main" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  name                = "${var.cluster_id}-identity"
  tags                = var.azure_extra_tags
}

resource "azurerm_role_assignment" "main" {
  scope                = data.azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
}

resource "azurerm_role_assignment" "network" {
  count = var.azure_preexisting_network ? 1 : 0

  scope                = data.azurerm_resource_group.network[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
}

resource "time_sleep" "wait_60_seconds" {
  depends_on      = [azurerm_private_endpoint.private_endpoint]
  create_duration = "60s" 
}

# copy over the vhd to cluster resource group and create an image using that
/*
resource "azurerm_storage_container" "vhd" {
  name                 = "vhd"
  storage_account_name = azurerm_storage_account.cluster.name
  depends_on           = [time_sleep.wait_60_seconds]
}
*/

resource "azapi_resource" "vhd" {
   type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01"
   name      = "vhd"
   parent_id = "${azurerm_storage_account.cluster.id}/blobServices/default"
   body = {
      properties = {
      }
   }
   depends_on = [time_sleep.wait_60_seconds]
}

resource "azurerm_storage_blob" "rhcos_image" {
  name                   = "rhcos${var.random_storage_account_suffix}.vhd"
  storage_account_name   = azurerm_storage_account.cluster.name
  # storage_container_name = azurerm_storage_container.vhd.name
  storage_container_name = azapi_resource.vhd.name
  type                   = "Page"
  source_uri             = var.azure_image_url
  metadata               = tomap({ source_uri = var.azure_image_url })
  depends_on             = [time_sleep.wait_60_seconds]
}

# Creates Shared Image Gallery
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/shared_image_gallery
resource "azurerm_shared_image_gallery" "sig" {
  name                = "gallery_${replace(var.cluster_id, "-", "_")}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.azure_region
  tags                = var.azure_extra_tags
}

# Creates image definition
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/shared_image
resource "azurerm_shared_image" "cluster" {
  name                = var.cluster_id
  gallery_name        = azurerm_shared_image_gallery.sig.name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.azure_region
  os_type             = "Linux"
  architecture        = var.azure_vm_architecture

  identifier {
    publisher = "RedHat"
    offer     = "rhcos"
    sku       = "basic"
  }

  tags = var.azure_extra_tags
}

resource "azurerm_shared_image" "clustergen2" {
  name                = "${var.cluster_id}-gen2"
  gallery_name        = azurerm_shared_image_gallery.sig.name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  architecture        = var.azure_vm_architecture

  confidential_vm_supported = var.azure_master_security_encryption_type != null ? true : null

  trusted_launch_enabled = var.azure_master_security_encryption_type == null ? (var.azure_master_secure_boot == "Enabled" || var.azure_master_virtualized_trusted_platform_module == "Enabled") : null

  identifier {
    publisher = "RedHat-gen2"
    offer     = "rhcos-gen2"
    sku       = "gen2"
  }

  tags = var.azure_extra_tags
}

resource "azurerm_shared_image_version" "cluster_image_version" {
  name                = var.azure_image_release
  gallery_name        = azurerm_shared_image.cluster.gallery_name
  image_name          = azurerm_shared_image.cluster.name
  resource_group_name = azurerm_shared_image.cluster.resource_group_name
  location            = azurerm_shared_image.cluster.location

  blob_uri           = azurerm_storage_blob.rhcos_image.url
  storage_account_id = azurerm_storage_account.cluster.id

  target_region {
    name                   = azurerm_shared_image.cluster.location
    regional_replica_count = 1
  }

  tags = var.azure_extra_tags
}

resource "azurerm_shared_image_version" "clustergen2_image_version" {
  name                = var.azure_image_release
  gallery_name        = azurerm_shared_image.clustergen2.gallery_name
  image_name          = azurerm_shared_image.clustergen2.name
  resource_group_name = azurerm_shared_image.clustergen2.resource_group_name
  location            = azurerm_shared_image.clustergen2.location

  blob_uri           = azurerm_storage_blob.rhcos_image.url
  storage_account_id = azurerm_storage_account.cluster.id

  target_region {
    name                   = azurerm_shared_image.clustergen2.location
    regional_replica_count = 1
  }

  tags = var.azure_extra_tags
}

