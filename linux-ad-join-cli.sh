#!/bin/bash
#
# Linux AD Join Script
# --------------------
# A simple script to join Linux systems to an Active Directory domain.
# Supports multiple distros, sets up SSSD, SSH, and auto-handles reboots.
# License: MIT
#

set -euo pipefail

# ==============================
# Setup logging
# ==============================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/linux_ad_join.log"

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

# ==============================
# Minimal banner
# ==============================
show_banner() {
  echo
  echo "=============================================================="
  echo "            LinuxADJoin - Linux Active Directory Join          "
  echo "--------------------------------------------------------------"
  echo " A simple script to join Linux machines to Active Directory."
  echo " License: MIT"
  echo " Log File: $LOG_FILE"
  echo "=============================================================="
  echo
}

# ==============================
# Helpers
# ==============================
log() { echo "[*] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
ok()  { echo "[+] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
err() { echo "[!] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."
    exit 1
  fi
}

require_args() {
  if [[ $# -ne 6 ]]; then
    err "Usage: $0 <domain> <admin_user> <admin_pass> <hostname> <users_csv_or_none> <groups_csv_or_none>"
    exit 1
  fi
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VER="${VERSION_ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  else
    err "Cannot detect OS (no /etc/os-release)"
    exit 1
  fi
  log "Detected OS: $OS_ID $OS_VER (like: ${OS_LIKE:-n/a})"
}

assert_systemd() {
  if ! pidof systemd >/dev/null 2>&1; then
    err "This script requires systemd (systemctl)."
    exit 1
  fi
}

# -------------------------------
# Install required packages
# -------------------------------
install_packages() {
  log "Installing required packages..."
  case "$OS_ID" in
    rhel|centos|rocky|almalinux|fedora|ol|amzn)
      PKG="dnf"; command -v dnf >/dev/null 2>&1 || PKG="yum"
      $PKG -y install realmd sssd sssd-tools oddjob oddjob-mkhomedir adcli \
                       samba-common-tools krb5-workstation chrony || true
      ;;
    ubuntu|debian|pop|linuxmint|zorin|elementary|kali|parrot)
      apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        realmd sssd sssd-tools adcli packagekit samba-common-bin \
        libnss-sss libpam-sss chrony krb5-user oddjob oddjob-mkhomedir || true
      ;;
    sles|suse|opensuse*|opensuse-leap|opensuse-tumbleweed|leap|tumbleweed)
      zypper --non-interactive refresh || true
      zypper --non-interactive install realmd sssd sssd-tools adcli samba-client \
                                       krb5-client chrony oddjob oddjob-mkhomedir || true
      ;;
    arch|manjaro)
      pacman -Sy --noconfirm --needed realmd sssd sssd-tools oddjob \
        oddjob-mkhomedir adcli samba krb5 chrony || true
      ;;
    *)
      if [[ "${OS_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
        PKG="dnf"; command -v dnf >/dev/null 2>&1 || PKG="yum"
        $PKG -y install realmd sssd sssd-tools oddjob oddjob-mkhomedir adcli \
                         samba-common-tools krb5-workstation chrony || true
      elif [[ "${OS_LIKE:-}" =~ (debian|ubuntu) ]]; then
        apt-get update -y || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
          realmd sssd sssd-tools adcli packagekit samba-common-bin \
          libnss-sss libpam-sss chrony krb5-user oddjob oddjob-mkhomedir || true
      elif [[ "${OS_LIKE:-}" =~ (suse|opensuse) ]]; then
        zypper --non-interactive refresh || true
        zypper --non-interactive install realmd sssd sssd-tools adcli samba-client \
                                         krb5-client chrony oddjob oddjob-mkhomedir || true
      elif [[ "${OS_LIKE:-}" =~ (arch) ]]; then
        pacman -Sy --noconfirm --needed realmd sssd sssd-tools oddjob \
          oddjob-mkhomedir adcli samba krb5 chrony || true
      else
        log "Unknown OS: $OS_ID. Please install dependencies manually."
      fi
      ;;
  esac
  ok "Package install step completed (best-effort)."
}

configure_time_sync() {
  log "Configuring time sync..."
  timedatectl set-ntp true || true
  systemctl enable --now chronyd 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null || true
  ok "Time sync configured."
}

set_hostname_from_arg() {
  local NEW_HOSTNAME="$1"
  log "Setting hostname to: $NEW_HOSTNAME"
  hostnamectl set-hostname "$NEW_HOSTNAME" || true
  ok "Hostname set to: $(hostname)"
}

discover_realm() {
  local DOMAIN="$1"
  log "Discovering AD realm for $DOMAIN..."
  if ! realm discover -v "$DOMAIN"; then
    err "Realm discovery failed. Check DNS and network."
    exit 1
  fi
  ok "Realm discovery successful."
}

join_realm() {
  local DOMAIN="$1"; local ADMIN="$2"; local PASS="$3"
  local DOMAIN_UPPER
  DOMAIN_UPPER="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"
  log "Joining AD domain $DOMAIN_UPPER using account $ADMIN..."
  if ! echo "$PASS" | realm join --verbose --user="$ADMIN" "$DOMAIN_UPPER"; then
    err "Realm join failed. Verify credentials and DNS/network."
    exit 1
  fi
  ok "Successfully joined AD domain $DOMAIN_UPPER."
}

enable_mkhomedir() {
  log "Enabling automatic home directory creation..."
  if command -v authselect >/dev/null 2>&1; then
    authselect select sssd with-mkhomedir --force >/dev/null 2>&1 || true
  elif command -v pam-auth-update >/dev/null 2>&1; then
    pam-auth-update --enable mkhomedir --force >/dev/null 2>&1 || true
  elif command -v pam-config >/dev/null 2>&1; then
    pam-config -a --mkhomedir >/dev/null 2>&1 || true
  fi
  ok "mkhomedir enabled."
}

# -------------------------------
# CSV Parsing
# -------------------------------
csv_to_space() {
  local in="${1:-}"; in="${in,,}"
  if [[ -z "$in" || "$in" == "none" ]]; then
    echo ""
  else
    echo "$in" | tr ',' ' ' | xargs
  fi
}

compose_allowed_users() { csv_to_space "$1"; }
compose_allowed_groups() { csv_to_space "$1"; }

# -------------------------------
# Configure SSSD
# -------------------------------
configure_sssd() {
  local DOMAIN="$1" users_space="$2" groups_space="$3"
  local sssd_conf="/etc/sssd/sssd.conf"
  local DOMAIN_UPPER
  DOMAIN_UPPER="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"

  log "Writing SSSD config..."
  if [[ -f "$sssd_conf" ]]; then
    cp -a "$sssd_conf" "${sssd_conf}.bak.$(date +%s)" || true
  fi

  local users_csv groups_csv
  users_csv="$(echo "$users_space" | xargs | tr ' ' ',')"
  groups_csv="$(echo "$groups_space" | xargs | tr ' ' ',')"

  cat > "$sssd_conf" <<EOF
[sssd]
services = nss, pam, ssh
config_file_version = 2
domains = $DOMAIN

[domain/$DOMAIN]
ad_domain = $DOMAIN
krb5_realm = $DOMAIN_UPPER
id_provider = ad
access_provider = simple
use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash
EOF

  [[ -n "$users_csv" ]] && echo "simple_allow_users = $users_csv" >> "$sssd_conf"
  [[ -n "$groups_csv" ]] && echo "simple_allow_groups = $groups_csv" >> "$sssd_conf"

  chmod 600 "$sssd_conf" || true

  systemctl enable --now sssd >/dev/null 2>&1 || true
  systemctl restart sssd >/dev/null 2>&1 || true

  # Clear SSSD cache so new rules apply immediately
  systemctl stop sssd >/dev/null 2>&1 || true
  rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
  systemctl start sssd >/dev/null 2>&1 || true

  ok "SSSD configured."
}

configure_sshd() {
  log "Ensuring SSH password login enabled..."
  sed -i 's/^[#[:space:]]*PasswordAuthentication[[:space:]]\+.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || true
  ok "SSHD config updated."
}

apply_realm_permit() {
  local users_space="$1" groups_space="$2"
  log "Applying realm permit rules..."
  realm permit --all >/dev/null 2>&1 || true
  for u in $users_space; do
    realm permit "$u" >/dev/null 2>&1 || true
  done
  for g in $groups_space; do
    realm permit -g "$g" >/dev/null 2>&1 || realm permit --groups="$g" >/dev/null 2>&1 || true
  done
  ok "Realm permit rules applied (best-effort)."
}

# -------------------------------
# Detect workstation vs server
# -------------------------------
detect_role() {
  local default_tgt dm_found="no"
  default_tgt="$(systemctl get-default 2>/dev/null || echo unknown)"
  for dm in gdm sddm lightdm lxdm; do
    if systemctl is-enabled "$dm".service >/dev/null 2>&1 || systemctl is-active "$dm".service >/dev/null 2>&1; then
      dm_found="yes"; break
    fi
  done
  [[ "$default_tgt" == "graphical.target" || "$dm_found" == "yes" ]] && echo "workstation" || echo "server"
}

finalize_and_reboot() {
  local role="$1"
  echo "============================================="
  echo " AD domain join completed successfully!"
  echo " Detected role: $role"
  echo " Logs saved to: $LOG_FILE"
  echo "============================================="

  if [[ "$role" == "server" ]]; then
    echo "[*] Server detected: rebooting automatically..."
    sleep 3; reboot
  else
    read -r -p "[?] Workstation detected. Reboot now? [y/N]: " ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] && reboot || echo "[*] Skipping reboot. Please reboot later."
  fi
}

# ==============================
# MAIN
# ==============================
main() {
  show_banner
  need_root
  require_args "$@"
  assert_systemd

  DOMAIN="$1"
  ADMIN_USER="$2"
  ADMIN_PASS="$3"
  HOSTNAME_ARG="$4"
  USERS_CSV="$5"
  GROUPS_CSV="$6"

  detect_os
  install_packages
  configure_time_sync
  set_hostname_from_arg "$HOSTNAME_ARG"
  discover_realm "$DOMAIN"
  join_realm "$DOMAIN" "$ADMIN_USER" "$ADMIN_PASS"
  enable_mkhomedir

  USERS_SPACE="$(compose_allowed_users "$USERS_CSV")"
  GROUPS_SPACE="$(compose_allowed_groups "$GROUPS_CSV")"

  [[ -n "$USERS_SPACE" ]] && log "Final allowed users: $USERS_SPACE" || log "No allowed users specified."
  [[ -n "$GROUPS_SPACE" ]] && log "Final allowed groups: $GROUPS_SPACE" || log "No allowed groups specified."

  configure_sssd "$DOMAIN" "$USERS_SPACE" "$GROUPS_SPACE"
  configure_sshd
  apply_realm_permit "$USERS_SPACE" "$GROUPS_SPACE"

  role="$(detect_role)"
  finalize_and_reboot "$role"
}

main "$@"
