output "resource_group_name" {
  description = "Resource group name for Hive"
  value       = azurerm_resource_group.hive.name
}

output "dns_zone_name" {
  description = "DNS zone for Hive spokes"
  value       = azurerm_dns_zone.hive.name
}

output "dns_zone_name_servers" {
  description = "Name servers — à configurer dans ton registrar DNS"
  value       = azurerm_dns_zone.hive.name_servers
}

output "resource_group_id" {
  description = "Resource group ID"
  value       = azurerm_resource_group.hive.id
}
