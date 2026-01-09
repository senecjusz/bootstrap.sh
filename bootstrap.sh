#!/usr/bin/env bash
set -euo pipefail

# Ubuntu bootstrap (public-safe defaults)
# - Azure-friendly: can operate on existing cloud user (no new user creation)
# - Hostname + local FQDN aliases
# - Tailscale install + up
# - authorized_keys provisioning (GitHub .keys / URL / local copy)
# - UFW rules
# - SSH hardening (default port 22222)
# - unattended-upgrades

log() { printf "\n[%s] %s\n" "$(date -Is)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }
bool_true() { case "${1:-false}" in 1|true|TRUE|yes|YES|y|Y) return 0 ;; *) return 1 ;; esac; }

# =========================
# ENV (override as needed)
# =========================
HOSTNAME_SHORT="${HOSTNAME_SHORT:-}"       # required
TS_AUTHKEY="${TS_AUTHKEY:-}"               # required

PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-example.com}"
EXTRA_DOMAINS="${EXTRA_DOMAINS:-}"         # comma-separated

# User management:
# - MANAGE_USER=true  => create NEW_USER and grant sudo (classic mode)
# - MANAGE_USER=false => do not create users; operate on TARGET_USER (cloud mode)
MANAGE_USER="${MANAGE_USER:-false}"

# Public-safe default username (placeholder). Set real user via env in runtime.
NEW_USER="${NEW_USER:-superadmin}"

# Target user for authorized_keys provisioning (when MANAGE_USER=false):
# If empty, script uses SUDO_USER (recommended).
TARGET_USER="${TARGET_USER:-}"

# SSH / Firewall
SSH_PORT="${SSH_PORT:-22222}"
KEEP_SSH_PORT_22="${KEEP_SSH_PORT_22:-true}"

# authorized_keys source (pick one):
GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-}"       # https://github.com/<user>.keys
AUTHORIZED_KEYS_URL="${AUTHORIZED_KEYS_URL:-}" # URL to authorized_keys file

require_vars() {
  [[ -n "${HOSTNAME_SHORT}" ]] || die "HOSTNAME_SHORT is required."
  [[ -n "${TS_AUTHKEY}" ]] || die "TS_AUTHKEY is required."
}

resolve_target_user() {
  if bool_true "${MANAGE_USER}"; then
    echo "${NEW_USER}"
    return 0
  fi

  if [[ -n "${TARGET_USER}" ]]; then
    echo "${TARGET_USER}"
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return 0
  fi

  die "TARGET_USER is empty and SUDO_USER is not set. Run via sudo or set TARGET_USER explicitly."
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

  echo "${primary} ${aliases[*]}"
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
  log "APT update/upgrade + base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y curl ca-certificates ufw unattended-upgrades
}

step_hostname_and_fqdn() {
  local fqdns
  fqdns="$(build_fqdns)"

  log "Set hostname: ${HOSTNAME_SHORT}"
  hostnamectl set-hostname "${HOSTNAME_SHORT}"

  log "Configure cloud-init preserve_hostname: true"
  mkdir -p /etc/cloud/cloud.cfg.d
  cat >/etc/cloud/cloud.cfg.d/99_preserve_hostname.cfg <<EOF
preserve_hostname: true
EOF

  log "Update /etc/hosts (127.0.1.1 -> ${fqdns} ${HOSTNAME_SHORT})"
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
  log "Install Tailscale and bring it up"
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up --authkey="${TS_AUTHKEY}" --hostname="${HOSTNAME_SHORT}"
}

step_user() {
  if ! bool_true "${MANAGE_USER}"; then
    log "Skipping user creation/sudo setup (MANAGE_USER=${MANAGE_USER})"
    return 0
  fi

  log "Create user ${NEW_USER} and grant sudo (NOPASSWD)"
  if ! id -u "${NEW_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${NEW_USER}"
  else
    log "User ${NEW_USER} already exists; skipping adduser"
  fi

  usermod -aG sudo "${NEW_USER}"

  local sudoers_file="/etc/sudoers.d/90-${NEW_USER}-nopasswd"
  echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "${sudoers_file}"
  chmod 0440 "${sudoers_file}"
  visudo -cf /etc/sudoers >/dev/null
  visudo -cf "${sudoers_file}" >/dev/null
}

step_ssh_keys() {
  local user
  user="$(resolve_target_user)"

  log "Install authorized_keys for user: ${user}"

  local home_dir
  home_dir="$(getent passwd "${user}" | cut -d: -f6)"
  [[ -n "${home_dir}" ]] || die "Cannot resolve home directory for user: ${user}"

  local target_dir="${home_dir}/.ssh"
  local target_file="${target_dir}/authorized_keys"

  mkdir -p "${target_dir}"
  chmod 700 "${target_dir}"

  if [[ -n "${AUTHORIZED_KEYS_URL}" ]]; then
    log "Downloading authorized_keys from URL"
    curl -fsSL "${AUTHORIZED_KEYS_URL}" > "${target_file}"
  elif [[ -n "${GITHUB_KEYS_USER}" ]]; then
    log "Downloading public keys from GitHub user: ${GITHUB_KEYS_USER}"
    curl -fsSL "https://github.com/${GITHUB_KEYS_USER}.keys" > "${target_file}"
  else
    local src
    src="$(detect_local_authorized_keys)"
    [[ -n "${src}" ]] || die "No authorized_keys source found. Set GITHUB_KEYS_USER or AUTHORIZED_KEYS_URL, or ensure ~/.ssh/authorized_keys exists."
    log "Copying local authorized_keys from: ${src}"
    cp "${src}" "${target_file}"
  fi

  grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))[[:space:]]' "${target_file}" \
    || die "authorized_keys looks empty/invalid."

  chmod 600 "${target_file}"
  chown -R "${user}:${user}" "${target_dir}"
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

ensure_sshd_dropin_supported() {
  local main="/etc/ssh/sshd_config"
  local include_line='Include /etc/ssh/sshd_config.d/*.conf'

  if ! grep -qE "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$" "${main}"; then
    log "Ensuring sshd_config includes /etc/ssh/sshd_config.d/*.conf"
    echo "" >> "${main}"
    echo "${include_line}" >> "${main}"
  fi

  mkdir -p /etc/ssh/sshd_config.d
}

step_sshd() {
  log "Harden SSH (drop-in) and set port to ${SSH_PORT}"
  ensure_sshd_dropin_supported

  local dropin="/etc/ssh/sshd_config.d/99-hardening.conf"
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"

  cat > "${dropin}" <<EOF
Port ${SSH_PORT}
PermitRootLogin no
MaxAuthTries 2
PermitEmptyPasswords no
PasswordAuthentication no
X11Forwarding no
Compression delayed
Protocol 2
EOF

  sshd -t
  systemctl reload ssh 2>/dev/null || service ssh reload
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
  echo "local FQDNs (/etc/hosts): $(build_fqdns)"
  echo "ssh port: ${SSH_PORT}"
  echo "manage user: ${MANAGE_USER}"
  echo "target user: $(resolve_target_user)"
}

main "$@"
