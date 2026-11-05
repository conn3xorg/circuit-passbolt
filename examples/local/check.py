"""Uses Passbolt the way its browser extension does, through its API.

The first run accepts the admin's invitation with a new OpenPGP key and checks
the invitation can't be used twice. Every run then signs in with that key over
Passbolt's GPG challenge, reads the admin's own profile with the token it gets
back, and checks a challenge signed by some other key is refused. The keys stay
in ./gnupg (or CHECK_GNUPGHOME), so later runs sign in as the same admin. Run by check.sh.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

base, domain, invite_file = sys.argv[1], sys.argv[2], sys.argv[3]
# CHECK_GNUPGHOME picks another place: gpg-agent refuses socket paths over
# about 100 characters, which a deep checkout can reach.
home = os.path.abspath(os.environ.get("CHECK_GNUPGHOME", "gnupg"))
os.makedirs(home, mode=0o700, exist_ok=True)
os.environ["GNUPGHOME"] = home


def call(method, path, body=None, token=None):
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def gpg(*args, data=None):
    out = subprocess.run(["gpg", "--batch", "--yes", "--quiet", "--trust-model", "always", *args],
                         input=data, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"gpg {' '.join(args)}: {out.stderr}")
    return out.stdout


def make_key(email):
    if email not in gpg("--list-keys"):
        gpg("--passphrase", "", "--quick-gen-key", f"Check <{email}>", "rsa3072", "sign,cert", "never")
        fpr = re.search(r"^fpr:+([0-9A-F]{40}):", gpg("--with-colons", "--list-keys", email), re.M)[1]
        gpg("--passphrase", "", "--quick-add-key", fpr, "rsa3072", "encr", "never")
    return gpg("--armor", "--export", email)


def login(user_id, signer):
    challenge = json.dumps({
        "version": "1.0.0",
        "domain": domain,
        "verify_token": str(uuid.uuid4()),
        "verify_token_expiry": int(time.time()) + 120,
    })
    armored = gpg("--armor", "--encrypt", "--sign", "--local-user", signer, "--recipient", server_fpr, data=challenge)
    return call("POST", "/auth/jwt/login.json", {"user_id": user_id, "challenge": armored}), json.loads(challenge)


# Passbolt may still be starting after a restart.
for _ in range(90):
    try:
        status, body = call("GET", "/healthcheck/status.json")
        if status == 200 and body["body"] == "OK":
            break
    except (urllib.error.URLError, ConnectionError, ValueError):
        pass
    time.sleep(2)
else:
    sys.exit("Passbolt didn't report OK on " + base)

user_id, token = re.search(r"/setup/start/([0-9a-f-]{36})/([0-9a-f-]{36})", open(invite_file).read()).groups()
email = "admin@example.com"

if not os.path.exists(os.path.join(home, "setup-done")):
    status, body = call("GET", f"/setup/start/{user_id}/{token}.json")
    assert status == 200, f"the invitation didn't open: {status} {body}"
    status, body = call("POST", f"/setup/complete/{user_id}.json",
                        {"authenticationtoken": {"token": token}, "gpgkey": {"armored_key": make_key(email)}})
    assert status == 200, f"completing the setup failed: {status} {body}"
    status, _ = call("GET", f"/setup/start/{user_id}/{token}.json")
    assert status != 200, "the invitation opened a second time"
    open(os.path.join(home, "setup-done"), "w").close()
    print("Accepted the admin's invitation, which then stopped working.")

status, body = call("GET", "/auth/verify.json")
assert status == 200, f"no server key: {status} {body}"
server_fpr = body["body"]["fingerprint"]
gpg("--import", data=body["body"]["keydata"])

(status, body), sent = login(user_id, email)
assert status == 200, f"sign-in failed: {status} {body}"
reply = json.loads(gpg("--decrypt", data=body["body"]["challenge"]))
assert reply["verify_token"] == sent["verify_token"], "the server's answer has another verify_token"

status, me = call("GET", "/users/me.json", token=reply["access_token"])
assert status == 200 and me["body"]["role"]["name"] == "admin", f"reading the profile failed: {status} {me}"
print(f"Signed in as {me['body']['username']}, role {me['body']['role']['name']}.")

make_key("intruder@example.com")
(status, body), _ = login(user_id, "intruder@example.com")
assert status != 200, "a challenge signed by another key was accepted"
print(f"A challenge signed by another key got {status}.")
