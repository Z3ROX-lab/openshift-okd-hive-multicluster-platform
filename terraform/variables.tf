variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
  sensitive   = true
}

variable "client_id" {
  description = "Azure Service Principal Client ID (hive-sp)"
  type        = string
  sensitive   = true
}

variable "client_secret" {
  description = "Azure Service Principal Client Secret (hive-sp)"
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group for Hive infrastructure"
  type        = string
  default     = "rg-hive-multicluster"
}

variable "dns_zone_name" {
  description = "DNS zone for Hive spoke clusters"
  type        = string
  default     = "hive.okd.lab"
}
