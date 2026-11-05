#!/usr/bin/env sh
# Runs check.py here against Passbolt in the host up.sh started, through an
# SSH tunnel, the way you'd reach a server that listens on 127.0.0.1.
# PORT is the host's SSH port, as for up.sh; TUNNEL_PORT the local end.
set -eu
cd "$(dirname "$0")"
port=${PORT:-2222}
tunnel=${TUNNEL_PORT:-18080}
ssh="ssh -i id_ed25519 -o UserKnownHostsFile=known_hosts -o BatchMode=yes -p $port"

$ssh root@127.0.0.1 cat /etc/passbolt/admin-invite.txt > admin-invite.txt
$ssh -o ExitOnForwardFailure=yes -N -L "127.0.0.1:$tunnel:127.0.0.1:8080" root@127.0.0.1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 2
python3 -I check.py "http://127.0.0.1:$tunnel" http://localhost:8080 admin-invite.txt
