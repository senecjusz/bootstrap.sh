# Ubuntu bootstrap

A script to quickly bootstrap a fresh Ubuntu server:

- `apt update/upgrade`
- set hostname + local FQDN (primary + aliases)
- install and bring up Tailscale
- create a user (default: `veloadmin`) + sudo
- install `authorized_keys` (from GitHub `.keys`, a URL, or locally)
- configure UFW
- SSH hardening (default port 10022, no passwords, no root login)
- `unattended-upgrades`

## Requirements

- Ubuntu
- run as `root` or via `sudo`

## Environment variables

Required:

- `HOSTNAME_SHORT` – short hostname (e.g. `hostname1`)
- `TS_AUTHKEY` – Tailscale auth key (`tskey-auth-...`)

Optional:

- `PRIMARY_DOMAIN` – canonical domain (default: `primarydomain.eu`)
- `EXTRA_DOMAINS` – additional domains (comma-separated), e.g. `domian2.eu,example.net`
- `NEW_USER` – username to create (default: `superadmin`)
- `SSH_PORT` – SSH port (default: `222222`)
- `KEEP_SSH_PORT_22` – keep port 22 open in UFW as a safety net (`true/false`, default: `true`)

SSH key source (choose one of the following):

- `GITHUB_KEYS_USER` – downloads keys from `https://github.com/<user>.keys`
- `AUTHORIZED_KEYS_URL` – downloads an `authorized_keys` file from the given URL (e.g. GitHub raw)
- if both are empty, the script tries to copy local `~/.ssh/authorized_keys` from the user running `sudo` or from `/root`

## Run (recommended – using a .env file)

Create a `.env` file:

```bash
cat > .env <<'EOF'
HOSTNAME_SHORT="xxx-hostname"
PRIMARY_DOMAIN="maindomain.eu"
EXTRA_DOMAINS="ts.seconddomain.eu"
TS_AUTHKEY="tskey-auth-REDACTED"

# optional:
# NEW_USER="superadmin"
# SSH_PORT="22222"
# KEEP_SSH_PORT_22="true"

# SSH keys (pick one):
GITHUB_KEYS_USER="senecjusz"
# AUTHORIZED_KEYS_URL="https://raw.githubusercontent.com/<org>/<repo>/<ref>/authorized_keys"
EOF

chmod 600 .env
```
