variable "port" {
  type    = number
  default = 2222
}

# Null keeps the circuit's pins. CI sets an older release here first, to
# test an upgrade.
variable "passbolt_version" {
  type    = string
  default = null
}

variable "image_digest" {
  type    = string
  default = null
}

module "passbolt" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # Matches an SSH tunnel to the host: ssh -L 8080:127.0.0.1:8080. On a real
  # host, this is the https address of the proxy in front.
  public_url = "http://localhost:8080"
  admin      = { email = "admin@example.com", first_name = "Ada", last_name = "Admin" }

  passbolt_version = var.passbolt_version
  image_digest     = var.image_digest
}

output "url" {
  value = module.passbolt.url
}
