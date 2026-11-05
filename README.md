# circuit-passbolt

[![Conn3x grade](https://conn3x.org/circuits/passbolt/grade.svg)](https://conn3x.org/circuits/passbolt/grade)

A Conn3x circuit that runs [Passbolt Community Edition](https://www.passbolt.com), the password manager built for teams, on your own hosts. Passwords are encrypted in each person's browser with their own OpenPGP key before they reach the server, and shared by encrypting them again for each person who should see them. The server never holds anything it could decrypt on its own.

Passbolt and its MariaDB database run from their official images under Podman as systemd services, pinned by tag and digest. Passbolt listens on `127.0.0.1:8080` for a reverse proxy with TLS in front. The database has no network at all: Passbolt reaches it over a Unix socket. Every secret the setup needs, the database passwords and Passbolt's own server key, is made on the host and never passes through Conn3x. If you name a first admin, the apply registers them and leaves their invitation link in a root-only file. It runs on Debian, Ubuntu, Fedora and Rocky Linux.

> **Back up `/var/lib/passbolt/gpg` with the database.** It holds the OpenPGP key Passbolt made for itself on its first start. Every sign-in is a challenge encrypted to that key, so a database restored without it is a database nobody can sign in to. Conn3x never sees the key, so it can't give it back to you either.

## Usage

```hcl
module "passbolt" {
  source = "github.com/conn3xorg/circuit-passbolt?ref=v0.1.0"

  hosts                = { vault = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  public_url = "https://passbolt.example.com"
  admin      = { email = "you@example.com", first_name = "Sam", last_name = "Rivera" }
}
```

Then run `conn3x init` and `conn3x apply`. The first apply takes a few minutes: it pulls both images, MariaDB sets itself up, and Passbolt makes its server key and installs its schema. A second `conn3x plan` says `No changes.`

Then read the invitation and open it in a browser with the [Passbolt extension](https://www.passbolt.com/download) installed:

```sh
ssh root@192.168.1.50 cat /etc/passbolt/admin-invite.txt
```

The extension makes your own key, asks for a passphrase and a recovery kit, and you're the admin. The link works once. The circuit registers the admin only while that file is missing, so to take it off the host, set `admin = null` first, apply, and then delete it.

To try it on a throwaway container first, see [examples/local](examples/local).

### public_url, and TLS in front

`public_url` is the address in the browser, and it matters more here than for most apps. Passbolt builds every link from it, and each sign-in carries it inside the encrypted challenge, which the server compares with its own setting. Sign in through any other address and Passbolt refuses. Change it, and people sign in at the new address.

Use `https`. The browser extension wants it, and passwords are exactly what you'd least want on a plain HTTP connection. Put a proxy in front for TLS, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) on the same host:

```hcl
module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.3.0"

  hosts                = { vault = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  sites = {
    "passbolt.example.com" = { reverse_proxy = ["127.0.0.1:8080"] }
  }
}
```

Passbolt itself speaks plain HTTP on `127.0.0.1:8080`, with `PASSBOLT_SSL_FORCE=false` so it doesn't redirect to HTTPS behind the proxy that's already providing it.

### Email

Passbolt sends invitations, password-share notices and account recovery by email. Without SMTP settings it can't send any, though the first admin's invitation still works, since the circuit writes it to a file. Give the settings in `environment`, which goes to a root-only file and never the plan or state:

```hcl
variable "smtp_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "passbolt" {
  # ...
  environment = {
    EMAIL_TRANSPORT_DEFAULT_HOST     = "smtp.example.com"
    EMAIL_TRANSPORT_DEFAULT_PORT     = "587"
    EMAIL_TRANSPORT_DEFAULT_USERNAME = "passbolt@example.com"
    EMAIL_TRANSPORT_DEFAULT_PASSWORD = var.smtp_password
    EMAIL_TRANSPORT_DEFAULT_TLS      = "true"
    EMAIL_DEFAULT_FROM               = "passbolt@example.com"
  }
}
```

Then **Administration**, **Email server** in Passbolt sends a test message. The variables are Passbolt's; its [docs](https://www.passbolt.com/docs/) list the rest.

### Registering an admin by hand

Leave `admin` out and register one yourself, in the container:

```sh
podman exec passbolt /usr/share/php/passbolt/bin/cake passbolt register_user \
  -u you@example.com -f Sam -l Rivera -r admin
```

It prints the invitation link.

## Why its own database

Passbolt's own Compose file runs MariaDB beside it, and that's what this circuit does, rather than asking you for a database. It means the circuit can make the database password on the host, where it never reaches the plan or state, and keep the database off the network entirely: MariaDB runs with no network, and its socket sits in `/var/lib/passbolt/run`, which only the two containers mount. Nothing else on the host or the network can connect to it.

If you'd rather keep Passbolt's data in a MariaDB or MySQL you already run, this circuit isn't the way. `DATASOURCES_*` aren't allowed in `environment`, so the database can't be swapped by accident.

## What it does

On each host, in order:

1. Creates `/etc/passbolt`, mode `0700`.
2. If `/etc/passbolt/passbolt.env` doesn't exist, makes two random passwords on the host and writes `db.env` (`MARIADB_PASSWORD`, `MARIADB_ROOT_PASSWORD`) and `passbolt.env` (`DATASOURCES_DEFAULT_PASSWORD`), mode `0600`. Once they exist the circuit never changes them: MariaDB sets them once, on its first start.
3. Creates `/var/lib/passbolt`, mode `0700`, with `mysql`, `gpg` and `jwt` for the database, the server key and the JWT keys, and `run` for MariaDB's socket, owned by the image's `mysql` user.
4. Writes `/etc/passbolt/start.sh`, which Passbolt's container runs: it waits until MariaDB takes Passbolt's login, then starts Passbolt the way the image would.
5. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman) v0.1.0, installs Podman and runs `docker.io/library/mariadb:VERSION@DIGEST` as `passbolt-db.service`, with no network, and `docker.io/passbolt/passbolt:VERSION@DIGEST` as `passbolt.service`, publishing its port 8080 on `listen_address:port`. `environment` goes to `/etc/containers/env/passbolt.env`, mode `0600`, from an ephemeral value.
6. Waits up to 15 minutes for Passbolt's own status page to say `OK`, from inside its container. On a first start, Passbolt makes its server key and installs its schema before then; after an upgrade, it runs its migrations. This runs again whenever the images or settings change.
7. With `admin`, registers that person as an admin once, and writes the invitation to `/etc/passbolt/admin-invite.txt`, mode `0600`.

Passbolt runs as the image's `www-data` user, in the `ce-non-root` images. Podman hands it `gpg` and `jwt` as it starts; only root can enter their parent.

### Upgrades

Change `passbolt_version` and `image_digest` together. `conn3x plan` shows the new image in the unit; the apply restarts Passbolt on it and waits while it migrates the database. CI applies 5.16.0 first, accepts the invitation and signs in, then upgrades to 5.17.0 and signs in again with the same key. Read Passbolt's [release notes](https://github.com/passbolt/passbolt_api/releases) before a major version.

MariaDB's `mariadb_version` can move within 10.11 the same way. Moving to a newer series is MariaDB's own upgrade, which the image runs on start when you set `MARIADB_AUTO_UPGRADE`; the circuit doesn't set it.

### What it doesn't do

- It doesn't set up TLS or a reverse proxy, and the browser extension expects HTTPS.
- It doesn't open a port in a firewall.
- It doesn't back anything up. Back up `/var/lib/passbolt/mysql` (or a `mariadb-dump` from the `passbolt-db` container), `/var/lib/passbolt/gpg` and `/etc/passbolt`, for instance with [circuit-restic](https://github.com/conn3xorg/circuit-restic).
- It doesn't run Passbolt Pro, or use a database of your own.
- Deleting the module leaves Podman, the containers, `/etc/passbolt` and `/var/lib/passbolt` in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.50"`, or a host object such as `{ address = "192.168.1.50", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `public_url` | string | Required | The address people reach Passbolt at, such as `"https://passbolt.example.com"`, with no path. Sets `APP_FULL_BASE_URL`. |
| `admin` | object | `null` | The first admin to register: `email`, `first_name` and `last_name`. When null, register one yourself. |
| `server_key_email` | string | `null` | Email address on the server key Passbolt makes on its first start. When null, `passbolt@` and the host of `public_url`. |
| `listen_address` | string | `"127.0.0.1"` | Address Passbolt listens on for plain HTTP. |
| `port` | number | `8080` | Port Passbolt listens on. |
| `environment` | map(string) | `{}` | More of Passbolt's environment variables, such as the `EMAIL_TRANSPORT_DEFAULT_*` ones. Ephemeral and sensitive: they go into a root-only env file and never the plan or state. `DATASOURCES_*` and the variables the circuit sets itself aren't allowed. |
| `passbolt_version` | string | `"5.17.0-1-ce-non-root"` | Tag of `docker.io/passbolt/passbolt`. Only `ce-non-root` tags fit. Change `image_digest` with it. |
| `image_digest` | string | `"sha256:ef8f2cb5..."` | Digest of the Passbolt image for `passbolt_version`. Find it on [Docker Hub](https://hub.docker.com/r/passbolt/passbolt/tags). |
| `mariadb_version` | string | `"10.11.19"` | Tag of `docker.io/library/mariadb`. Change `mariadb_digest` with it. |
| `mariadb_digest` | string | `"sha256:d769e379..."` | Digest of the MariaDB image for `mariadb_version`. |

## Outputs

| Name | Description |
| --- | --- |
| `services` | `passbolt.service` and `passbolt-db.service`. |
| `url` | Where Passbolt answers on the host, such as `http://127.0.0.1:8080`. Point a reverse proxy here. |
| `images` | The images the hosts run, with tags and digests. |
| `admin_invite_file` | `/etc/passbolt/admin-invite.txt`, or null without `admin`. |
| `backup_paths` | What to back up: `/var/lib/passbolt/mysql`, `/var/lib/passbolt/gpg` and `/etc/passbolt`. |

## Requirements

Requires Conn3x v0.7.0 or later and systemd on each host. The images are built for amd64 and arm64. Each host needs to reach its package mirror and Docker Hub. `conn3x init` fetches circuit-podman from GitHub.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, with Passbolt 5.16.0 first, then upgrades to 5.17.0 and checks that the next plan has no changes. Through an SSH tunnel, the check does what the browser extension does: it opens the admin's invitation, completes the setup with a new OpenPGP key, and checks the invitation can't be opened again. Then it signs in over Passbolt's GPG challenge, reads the admin's profile with the token it gets back, and checks a challenge signed by another key is refused. It runs after the first apply, after the upgrade, and after CI restarts the host. The generated database passwords and the invitation token aren't in state.

By hand, on two DigitalOcean droplets with 2 GB of memory, Ubuntu 24.04 and Rocky Linux 10 with SELinux enforcing, each running this circuit next to circuit-portainer and circuit-semaphore: the same upgrade from 5.16.0, the same checks, and a reboot after which Passbolt and MariaDB came back on their own, the admin signed in again with the same key, and the plan was clean. The Rocky audit log had no SELinux denials, and no generated secret was in state.

## License

MPL-2.0. See [LICENSE](LICENSE).

Passbolt Community Edition is under the [AGPL-3.0](https://github.com/passbolt/passbolt_api/blob/master/LICENSE.txt). Running it for your own team is fine; if you change Passbolt's code and let others use it over a network, the AGPL asks you to offer them your changes. MariaDB is under the GPL-2.0. Passbolt is a trademark of Passbolt SA; this circuit isn't affiliated with Passbolt SA.
