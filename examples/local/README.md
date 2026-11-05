# Local example

Applies circuit-passbolt to a throwaway Rocky Linux 10 container with systemd, with a first admin, `admin@example.com`. You need Conn3x, Podman, Python 3 and GnuPG.

Passbolt and MariaDB run under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs Podman, pulls both images, waits while MariaDB sets itself up and Passbolt installs its schema, and registers the admin. The second plan says `No changes.`

Then run the check CI runs:

```sh
./check.sh
```

It reads the admin's invitation from the container, opens an SSH tunnel to Passbolt on `127.0.0.1:8080`, and does what the browser extension would: completes the setup with a new OpenPGP key and signs in with it. The key lives in `./gnupg`, never in your own keyring. If GnuPG complains that a socket name is too long, as it can in a deep checkout, set `CHECK_GNUPGHOME` to a shorter directory for `check.sh` and `down.sh`.

To open Passbolt in a browser with the extension, forward the port and open `http://localhost:8080`, the `public_url` in `main.tf`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8080:127.0.0.1:8080 root@127.0.0.1
```

The invitation works once, so open it either in the browser or with `check.sh`, not both.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT` and to `check.sh` as `PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the keys and the state.
