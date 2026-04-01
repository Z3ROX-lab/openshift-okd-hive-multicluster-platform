terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret
}

# Resource Group dédié Hive
resource "azurerm_resource_group" "hive" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project     = "okd-hive-multicluster"
    managed-by  = "terraform"
    owner       = "Z3ROX-lab"
  }
}

# DNS Zone pour les spokes Hive
resource "azurerm_dns_zone" "hive" {
  name                = var.dns_zone_name
  resource_group_name = azurerm_resource_group.hive.name

  tags = {
    project    = "okd-hive-multicluster"
    managed-by = "terraform"
  }
}
