variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "public_url" {
  type        = string
  description = "The address people reach Passbolt at, such as \"https://passbolt.example.com\". Passbolt builds every link from it and checks it at each sign-in, so it must be the address in the browser. Use https: the browser extension expects it."

  validation {
    condition     = can(regex("^https?://[A-Za-z0-9.-]+(:[0-9]+)?/?$", var.public_url))
    error_message = "public_url must be an http or https address with no path, such as \"https://passbolt.example.com\"."
  }
}

variable "admin" {
  type = object({
    email      = string
    first_name = string
    last_name  = string
  })
  default     = null
  description = "The first admin to register, such as { email = \"you@example.com\", first_name = \"Sam\", last_name = \"Rivera\" }. The first apply writes their invitation link to /etc/passbolt/admin-invite.txt on the host. When null, register one yourself, as the README shows."

  validation {
    condition     = var.admin == null || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+$", try(var.admin.email, "")))
    error_message = "admin.email must be an email address."
  }

  validation {
    condition     = var.admin == null || (can(regex("^[\\p{L}][\\p{L} .-]*$", try(var.admin.first_name, ""))) && can(regex("^[\\p{L}][\\p{L} .-]*$", try(var.admin.last_name, ""))))
    error_message = "admin.first_name and admin.last_name may use letters, spaces, dots and hyphens."
  }
}

variable "server_key_email" {
  type        = string
  default     = null
  description = "Email address on the OpenPGP key Passbolt makes for itself on its first start. When null, passbolt@ and the host of public_url."

  validation {
    condition     = var.server_key_email == null || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$", coalesce(var.server_key_email, "-")))
    error_message = "server_key_email must be an email address."
  }
}

variable "passbolt_version" {
  type        = string
  default     = "5.17.0-1-ce-non-root"
  nullable    = false
  description = "Tag of the docker.io/passbolt/passbolt image, such as \"5.17.0-1-ce-non-root\". Only the ce-non-root images fit: they serve on port 8080 as an ordinary user. Change image_digest with it."

  validation {
    condition     = can(regex("^[0-9][A-Za-z0-9_.-]*-ce-non-root$", var.passbolt_version))
    error_message = "passbolt_version must be a ce-non-root tag, such as \"5.17.0-1-ce-non-root\"."
  }
}

variable "image_digest" {
  type        = string
  default     = "sha256:ef8f2cb58b671ff9ad888ce05d0f48d788dd3538bb09b1d4fc07f4c026c1d70b"
  nullable    = false
  description = "Digest of docker.io/passbolt/passbolt for passbolt_version. Podman pulls by the digest, so a tag that moves upstream can't change what runs."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a sha256 digest, such as \"sha256:\" followed by 64 hex digits."
  }
}

variable "mariadb_version" {
  type        = string
  default     = "10.11.19"
  nullable    = false
  description = "Tag of the docker.io/library/mariadb image for Passbolt's database, such as \"10.11.19\". 10.11 is the series Passbolt's own Compose file uses. Change mariadb_digest with it."

  validation {
    condition     = can(regex("^[0-9][A-Za-z0-9_.-]*$", var.mariadb_version))
    error_message = "mariadb_version must be an image tag, such as \"10.11.19\"."
  }
}

variable "mariadb_digest" {
  type        = string
  default     = "sha256:d769e37960821dfdcf096954f6e7ac89f747e116c1bba98e48edd265dfc7deae"
  nullable    = false
  description = "Digest of docker.io/library/mariadb for mariadb_version."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.mariadb_digest))
    error_message = "mariadb_digest must be a sha256 digest, such as \"sha256:\" followed by 64 hex digits."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address Passbolt listens on for plain HTTP. The default keeps it on the host, for a reverse proxy with TLS in front."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\"."
  }
}

variable "port" {
  type        = number
  default     = 8080
  description = "Port Passbolt listens on."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number from 1 to 65535."
  }
}

variable "environment" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "More of Passbolt's environment variables, such as { EMAIL_TRANSPORT_DEFAULT_HOST = \"smtp.example.com\", EMAIL_TRANSPORT_DEFAULT_PASSWORD = \"...\" }. They go in a root-only env file and never reach the plan or state."

  validation {
    condition     = alltrue([for k, v in var.environment : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")])
    error_message = "environment maps variable names, such as EMAIL_TRANSPORT_DEFAULT_HOST, to values on one line."
  }

  validation {
    condition     = length([for k in keys(var.environment) : k if startswith(k, "DATASOURCES_") || contains(["APP_FULL_BASE_URL", "PASSBOLT_SSL_FORCE", "PASSBOLT_KEY_EMAIL", "PASSBOLT_KEY_NAME"], k)]) == 0
    error_message = "The circuit sets APP_FULL_BASE_URL, PASSBOLT_SSL_FORCE, PASSBOLT_KEY_EMAIL, PASSBOLT_KEY_NAME and DATASOURCES_* itself. Use public_url and server_key_email."
  }
}
