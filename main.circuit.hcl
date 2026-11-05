locals {
  passbolt_image = "docker.io/passbolt/passbolt:${var.passbolt_version}@${var.image_digest}"
  mariadb_image  = "docker.io/library/mariadb:${var.mariadb_version}@${var.mariadb_digest}"

  etc         = "/etc/passbolt"
  state       = "/var/lib/passbolt"
  invite_file = "${local.etc}/admin-invite.txt"

  listen_host = strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address
  public_host = regex("^https?://([^/:]+)", var.public_url)[0]

  # MariaDB's socket, in a directory both containers mount. The database
  # has no network at all, so nothing but Passbolt can reach it.
  socket_dir = "${local.state}/run:/run/mysqld:z"

  # Waits until MariaDB takes Passbolt's login, then starts Passbolt the way
  # the image would. On a first start MariaDB sets itself up for a while,
  # and Passbolt's installer would fail without a database.
  start_script = <<-EOT
    #!/bin/bash
    # Managed by Conn3x.
    for _ in $(seq 300); do
      if php -r 'new PDO("mysql:host=localhost;dbname=" . getenv("DATASOURCES_DEFAULT_DATABASE"), getenv("DATASOURCES_DEFAULT_USERNAME"), getenv("DATASOURCES_DEFAULT_PASSWORD"));' 2>/dev/null; then
        exec /docker-entrypoint.sh
      fi
      sleep 1
    done
    echo "MariaDB didn't take Passbolt's login in 5 minutes. See journalctl -u passbolt-db." >&2
    exit 1
  EOT

  admin_command = var.admin == null ? "" : join(" ", [
    "/usr/share/php/passbolt/bin/cake passbolt register_user",
    "-u '${var.admin.email}'",
    "-f '${var.admin.first_name}'",
    "-l '${var.admin.last_name}'",
    "-r admin",
  ])
}

circuit "passbolt" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "etc" {
    directory {
      path  = local.etc
      owner = "root"
      group = "root"
      mode  = "0700"
    }
  }

  # The database password is made on the host by the first apply and never
  # passes through Conn3x, so it's in neither the plan nor state. MariaDB
  # sets it once, on its first start, so creates keeps it from changing.
  step "keys" {
    command {
      command = <<-EOT
        set -eu
        umask 077
        cd ${local.etc}
        pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
        root=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
        printf 'MARIADB_PASSWORD=%s\nMARIADB_ROOT_PASSWORD=%s\n' "$pw" "$root" > db.env.new
        printf 'DATASOURCES_DEFAULT_PASSWORD=%s\n' "$pw" > passbolt.env.new
        mv db.env.new db.env
        mv passbolt.env.new passbolt.env
      EOT
      creates = "${local.etc}/passbolt.env"
    }
  }

  # MariaDB's files, Passbolt's server key and JWT keys, in a parent only
  # root can enter. Podman hands gpg and jwt to the image's www-data user
  # as it starts. The socket directory belongs to the image's mysql user,
  # UID 999, which creates the socket in it.
  step "state" {
    command {
      command = "install -d -m 0700 ${local.state} && install -d -m 0700 ${local.state}/mysql ${local.state}/gpg ${local.state}/jwt && install -d -o 999 -g 999 -m 0755 ${local.state}/run"
      unless  = "[ \"$(stat -c '%u %a' ${local.state})\" = '0 700' ] && [ -d ${local.state}/jwt ] && [ \"$(stat -c '%u' ${local.state}/run)\" = 999 ]"
    }
  }

  step "start_script" {
    file {
      path    = "${local.etc}/start.sh"
      content = local.start_script
      owner   = "root"
      group   = "root"
      mode    = "0755"
    }
  }
}

module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.0"

  depends_on = [conn3x_command.passbolt__keys, conn3x_command.passbolt__state, conn3x_file.passbolt__start_script]

  hosts                = var.hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    passbolt-db = {
      image   = local.mariadb_image
      volumes = ["${local.state}/mysql:/var/lib/mysql:Z", local.socket_dir]
      environment = {
        MARIADB_DATABASE = "passbolt"
        MARIADB_USER     = "passbolt"
      }
      extra = ["Network=none", "EnvironmentFile=${local.etc}/db.env"]
    }

    passbolt = {
      image = local.passbolt_image
      ports = ["${local.listen_host}:${var.port}:8080"]
      volumes = [
        "${local.state}/gpg:/etc/passbolt/gpg:Z,U",
        "${local.state}/jwt:/etc/passbolt/jwt:Z,U",
        local.socket_dir,
        "${local.etc}/start.sh:/usr/local/bin/conn3x-start.sh:ro,Z",
      ]
      environment = {
        APP_FULL_BASE_URL            = trimsuffix(var.public_url, "/")
        DATASOURCES_DEFAULT_HOST     = "localhost"
        DATASOURCES_DEFAULT_USERNAME = "passbolt"
        DATASOURCES_DEFAULT_DATABASE = "passbolt"
        # TLS ends at the proxy in front, so Passbolt mustn't redirect to it.
        PASSBOLT_SSL_FORCE = "false"
        PASSBOLT_KEY_EMAIL = coalesce(var.server_key_email, "passbolt@${local.public_host}")
        PASSBOLT_KEY_NAME  = "Passbolt server key"
      }
      extra = ["EnvironmentFile=${local.etc}/passbolt.env", "Exec=/usr/local/bin/conn3x-start.sh"]
    }
  }
  secrets = {
    passbolt = var.environment
  }
}

circuit "ready" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # nginx answers before Passbolt has installed its schema or run its
  # migrations, so this waits on Passbolt's own status page, from inside its
  # container. It runs again whenever the images or settings change, since
  # those restart Passbolt.
  step "status" {
    depends_on = [module.podman]
    command {
      command  = "for _ in $(seq 180); do podman exec passbolt curl -fsS http://127.0.0.1:8080/healthcheck/status.json 2>/dev/null | grep -q '\"body\":\"OK\"' && exit 0; sleep 5; done; echo \"Passbolt didn't report OK in 15 minutes. See journalctl -u passbolt.\" >&2; exit 1"
      triggers = sha256(jsonencode([local.passbolt_image, local.mariadb_image, var.public_url, var.listen_address, var.port, var.server_key_email]))
    }
  }

  # Registers the first admin once. The invitation link holds a one-time
  # token, so it goes to a root-only file on the host rather than the plan,
  # state or the apply's output. The file stays, so the circuit never
  # registers a second admin.
  step "admin" {
    for_each   = toset(var.admin == null ? [] : ["admin"])
    depends_on = [conn3x_command.ready__status]
    command {
      command = "umask 077 && podman exec passbolt ${local.admin_command} > ${local.invite_file}.new && mv ${local.invite_file}.new ${local.invite_file}"
      creates = local.invite_file
    }
  }
}
