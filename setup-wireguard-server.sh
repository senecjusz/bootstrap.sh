#!/usr/bin/env bash
set -euo pipefail

# ---- Settings (you can override via env vars) ----
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SERVER_ADDR="${WG_SERVER_ADDR:-10.66.66.1/24}"
WG_CLIENT_ADDR="${WG_CLIENT_ADDR:-10.66.66.2/32}"
WG_ALLOWED_TO_SERVER_ONLY="${WG_ALLOWED_TO_SERVER_ONLY:-10.66.66.1/32}"  # split-tunnel: only server
WG_ENDPOINT="${WG_ENDPOINT:-}"  # REQUIRED: public DNS/IP of this server for client config

CLIENT_NAME="${CLIENT_NAME:-client1}"

WG_DIR="/etc/wireguard"
SERVER_KEY="$WG_DIR/server.key"
SERVER_PUB="$WG_DIR/server.pub"
CLIENT_KEY="$WG_DIR/${CLIENT_NAME}.key"
CLIENT_PUB="$WG_DIR/${CLIENT_NAME}.pub"
WG_CONF="$WG_DIR/${WG_IF}.conf"
CLIENT_CONF="/root/wg-${CLIENT_NAME}.conf"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (sudo)."
    exit 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wireguard
}

gen_keys_if_missing() {
  umask 077
  mkdir -p "$WG_DIR"
  chmod 700 "$WG_DIR"

  if [[ ! -f "$SERVER_KEY" ]]; then
    wg genkey | tee "$SERVER_KEY" >/dev/null
  fi
  if [[ ! -f "$SERVER_PUB" ]]; then
    wg pubkey < "$SERVER_KEY" | tee "$SERVER_PUB" >/dev/null
  fi

  if [[ ! -f "$CLIENT_KEY" ]]; then
    wg genkey | tee "$CLIENT_KEY" >/dev/null
  fi
  if [[ ! -f "$CLIENT_PUB" ]]; then
    wg pubkey < "$CLIENT_KEY" | tee "$CLIENT_PUB" >/dev/null
  fi
}

write_server_config() {
  local server_priv client_pub

  server_priv="$(cat "$SERVER_KEY")"
  client_pub="$(cat "$CLIENT_PUB")"

  if [[ -f "$WG_CONF" ]]; then
    echo "Server config exists: $WG_CONF (will not overwrite)."
    return 0
  fi

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_SERVER_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${server_priv}

# No routing/NAT enabled here by design.
# This setup is intended for split-tunnel to reach ONLY this server via its WG IP.

[Peer]
PublicKey = ${client_pub}
AllowedIPs = ${WG_CLIENT_ADDR}
EOF

  chmod 600 "$WG_CONF"
}

enable_and_start() {
  systemctl enable --now "wg-quick@${WG_IF}"
}

write_client_config() {
  local client_priv server_pub endpoint

  client_priv="$(cat "$CLIENT_KEY")"
  server_pub="$(cat "$SERVER_PUB")"

  endpoint="$WG_ENDPOINT"
  if [[ -z "$endpoint" ]]; then
    endpoint="CHANGE_ME_TO_PUBLIC_DNS_OR_IP"
  fi

  cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${WG_CLIENT_ADDR}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}:${WG_PORT}

# Split-tunnel: ONLY reach the server (its WG IP) through the tunnel.
AllowedIPs = ${WG_ALLOWED_TO_SERVER_ONLY}

# Helps when the client is behind NAT / mobile networks
PersistentKeepalive = 25
EOF

  chmod 600 "$CLIENT_CONF"
}

print_summary() {
  echo
  echo "Done."
  echo "Server interface: ${WG_IF} on ${WG_SERVER_ADDR} (UDP ${WG_PORT})"
  echo "Server public key: $(cat "$SERVER_PUB")"
  echo "Client config generated: ${CLIENT_CONF}"
  if [[ -z "$WG_ENDPOINT" ]]; then
    echo
    echo "IMPORTANT: WG_ENDPOINT was not set. Edit Endpoint in ${CLIENT_CONF}."
    echo "Example run:"
    echo "  WG_ENDPOINT=vpn.example.com sudo bash setup-wireguard-server.sh"
  fi
  echo
  echo "Check status:"
  echo "  sudo wg show"
  echo "  sudo systemctl status wg-quick@${WG_IF} --no-pager"
}

main() {
  need_root
  install_packages
  gen_keys_if_missing
  write_server_config
  enable_and_start
  write_client_config
  print_summary
}

main "$@"
