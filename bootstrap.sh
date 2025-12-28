#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date -Is)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }

# =========
# ENV VARS
# =========
HOSTNAME_SHORT="${HOSTNAME_SHORT:-}"          # required, e.g. lwe-bael
TS_AUTHKEY="${TS_AUTHKEY:-}"                  # required, tskey-auth-...

PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-archax.eu}"  # canonical FQDN domain
EXTRA_DOMAINS="${EXTRA_DOMAINS:-}"            # comma-separated, e.g. "ts.archax.eu,shase.net"

NEW_USER="${NEW_USER:-veloadmin}"
SSH_PORT="${SSH_PORT:-10022}"
KEEP_SSH_PORT_22="${KEEP_SSH_PORT_22:-true}"

# Optional SSH key sources:
AUTHORIZED_KEYS_URL="${AUTHORIZED_KEYS_URL:-}"  # raw URL to authorized_keys file
GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-}"        # downloads https://github.com/<user>.keys

bool_true() { case "${1:-false}" in 1|true|TRUE|yes|YES|y|Y) return 0;; *) return 1;; esac; }

require_vars() {
  [[ -n "${HOSTNAME_SHORT}" ]] || die "HOSTNAME_SHORT is required."
  [[ -n "${TS_AUTHKEY}" ]] || die "TS_AUTHKEY is required."
}

build_fqdns() {
  local primary="${HOSTNAME_SHORT}.${PRIMARY_DOMAIN}"
  local aliases=()

  if [[ -n "${EXTRA_DOMAINS}" ]]; then
    IFS=',' read -r -a doms <<< "${EXTRA_DOMAINS}"
    for d in "${doms[@]}"; do
      d="${d#"${d%%[![:space:]]*}"}"
      d="${d%"${d##*[![:space:]]}"}"
      [[ -n "${d}" ]] || continue
      aliases+=("${HOSTNAME_SHORT}.${d}")
    done
  fi

  # Output: primary first, then aliases
  echo "${primary} ${aliases[*]}"
}

# Idempotent sshd directive setter (replace if present, else append)
set_sshd_directive() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -qiE "^[[:space:]]*${key}[[:space:]]+" "${file}"; then
    perl -0777 -i -pe "s/^[[:space:]]*${key}[[:space:]]+.*\$/${key} ${value}/im" "${file}"
  else
    echo "${key} ${value}" >> "${file}"
  fi
}

detect_local_authorized_keys() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]]; then
    echo "/home/${SUDO_USER}/.ssh/authorized_keys"
    return 0
  fi
  if [[ -f "/root/.ssh/authorized_keys" ]]; then
    echo "/root/.ssh/authorized_keys"
    return 0
  fi
  echo ""
}

step_apt() {
  log "sudo apt update && sudo apt upgrade -y"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y curl ca-certificates ufw unattended-upgrades
}

step_hostname_and_fqdn() {
  local fqdns
  fqdns="$(build_fqdns)"

  log "sudo hostnamectl set-hostname ${HOSTNAME_SHORT}"
  hostnamectl set-hostname "${HOSTNAME_SHORT}"

  # Prevent cloud-init from resetting hostname on reboot (common in cloud)
  log "cloud-init preserve_hostname: true"
  mkdir -p /etc/cloud/cloud.cfg.d
  cat >/etc/cloud/cloud.cfg.d/99_preserve_hostname.cfg <<EOF2
preserve_hostname: true
EOF2

  # Local resolution (you manage external DNS yourself)
  log "Setting /etc/hosts aliases (127.0.1.1 -> ${fqdns} ${HOSTNAME_SHORT})"
  cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)"

  if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then
    awk -v names="${fqdns} ${HOSTNAME_SHORT}" '
      $1=="127.0.1.1" { print "127.0.1.1", names; next }
      { print }
    ' /etc/hosts > /etc/hosts.tmp && mv /etc/hosts.tmp /etc/hosts
  else
    echo "127.0.1.1 ${fqdns} ${HOSTNAME_SHORT}" >> /etc/hosts
  fi
}

step_tailscale() {
  log "Install tailscale + tailscale up (simple)"
  curl -fsSL https://tailscale.com/install.sh | sh
  # Correct flag is --authkey (not --auth-key)
  tailscale up --authkey="${TS_AUTHKEY}" --hostname="${HOSTNAME_SHORT}"
}

step_user() {
  log "Create user ${NEW_USER} and grant sudo + NOPASSWD"
  if ! id -u "${NEW_USER}" >/dev/null 2>&1; then
    # Non-interactive (safer for automation than plain adduser)
    adduser --disabled-password --gecos "" "${NEW_USER}"
  else
    log "User ${NEW_USER} already exists; skipping adduser"
  fi

  usermod -aG sudo "${NEW_USER}"

  cp /etc/sudoers /etc/sudoers.bak

  # Prefer sudoers.d (equivalent effect, safer than appending to /etc/sudoers)
  local sudoers_file="/etc/sudoers.d/90-${NEW_USER}-nopasswd"
  echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "${sudoers_file}"
  chmod 0440 "${sudoers_file}"
  visudo -cf /etc/sudoers >/dev/null
  visudo -cf "${sudoers_file}" >/dev/null
}

step_ssh_keys() {
  log "Install authorized_keys for ${NEW_USER}"
  local target_dir="/home/${NEW_USER}/.ssh"
  local target_file="${target_dir}/authorized_keys"

  mkdir -p "${target_dir}"
  chmod 700 "${target_dir}"

  if [[ -n "${AUTHORIZED_KEYS_URL}" ]]; then
    log "Downloading authorized_keys from URL"
    curl -fsSL "${AUTHORIZED_KEYS_URL}" > "${target_file}"
  elif [[ -n "${GITHUB_KEYS_USER}" ]]; then
    log "Downloading keys from https://github.com/${GITHUB_KEYS_USER}.keys"
    curl -fsSL "https://github.com/${GITHUB_KEYS_USER}.keys" > "${target_file}"
  else
    local src
    src="$(detect_local_authorized_keys)"
    [[ -n "${src}" ]] || die "No authorized_keys found. Set AUTHORIZED_KEYS_URL or GITHUB_KEYS_USER, or ensure ~/.ssh/authorized_keys exists for the invoking user."
    cp "${src}" "${target_file}"
  fi

  grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))[[:space:]]' "${target_file}" \
    || die "authorized_keys looks empty/invalid."

  chmod 600 "${target_file}"
  chown -R "${NEW_USER}:${NEW_USER}" "${target_dir}"
}

step_ufw() {
  log "Configure UFW"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  if bool_true "${KEEP_SSH_PORT_22}"; then
    ufw allow 22/tcp
  fi
  ufw allow "${SSH_PORT}"/tcp
  ufw allow in on tailscale0

  ufw --force enable
  ufw status verbose || true
}

step_sshd() {
  log "Harden SSH and move port to ${SSH_PORT}"
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"

  set_sshd_directive "PermitRootLogin" "no"
  set_sshd_directive "MaxAuthTries" "2"
  set_sshd_directive "PermitEmptyPasswords" "no"
  set_sshd_directive "PasswordAuthentication" "no"
  set_sshd_directive "X11Forwarding" "no"
  set_sshd_directive "Compression" "delayed"
  set_sshd_directive "Protocol" "2"
  set_sshd_directive "Port" "${SSH_PORT}"

  sshd -t
  service ssh reload
}

step_unattended() {
  log "Enable unattended-upgrades"
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  systemctl status unattended-upgrades --no-pager || true
}

main() {
  need_root
  require_vars

  step_apt
  step_hostname_and_fqdn
  step_tailscale
  step_user
  step_ssh_keys
  step_ufw
  step_sshd
  step_unattended

  log "DONE"
  echo "hostname: ${HOSTNAME_SHORT}"
  echo "FQDNs (local /etc/hosts): $(build_fqdns)"
  echo "SSH port: ${SSH_PORT} (UFW allows ${SSH_PORT} and optionally 22)"
  echo "User: ${NEW_USER}"
}

main "$@"
