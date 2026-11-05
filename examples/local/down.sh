#!/usr/bin/env sh
# Removes the container and everything up.sh and Conn3x created here.
set -eu
cd "$(dirname "$0")"
${PODMAN:-podman} rm -f -v "${CONTAINER_NAME:-circuit-passbolt}" >/dev/null 2>&1 || true
g=${CHECK_GNUPGHOME:-gnupg}
[ ! -d "$g" ] || GNUPGHOME=$(cd "$g" && pwd) gpgconf --kill all 2>/dev/null || true
rm -rf "$g"
rm -rf id_ed25519 id_ed25519.pub known_hosts .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup admin-invite.txt gnupg
echo "Removed."
