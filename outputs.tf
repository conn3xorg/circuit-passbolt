output "services" {
  description = "The systemd services that run Passbolt and its database on each host."
  value       = ["passbolt.service", "passbolt-db.service"]
}

output "url" {
  description = "Where Passbolt answers on each host itself, such as \"http://127.0.0.1:8080\". Point a reverse proxy here."
  value       = "http://${local.listen_host}:${var.port}"
}

output "images" {
  description = "The images the hosts run, with their tags and digests."
  value       = [local.passbolt_image, local.mariadb_image]
}

output "admin_invite_file" {
  description = "File on each host holding the first admin's invitation link, or null without admin. Open the link once and delete the file."
  value       = var.admin == null ? null : local.invite_file
}

output "backup_paths" {
  description = "What to back up on each host: the database and Passbolt's server key. Without the key, a restored database can't be read."
  value       = ["/var/lib/passbolt/mysql", "/var/lib/passbolt/gpg", "/etc/passbolt"]
}
