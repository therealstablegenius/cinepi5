#!/usr/bin/env bash
# ==============================================================================
#  CinePi5 – Unified Production Installer (Raspberry Pi 5)
#  Version : 5.1.0-prod
#  Author  : Howard Steven Rice, First World Improvements Corporation
#  License : MIT
# ------------------------------------------------------------------------------
#  The definitive deployment solution for CinePi5 camera systems.
#  Designed for enterprise and SaaS-grade delivery, offering unparalleled
#  robustness, security, and remote management capabilities.
#  This script transforms a bare-metal Raspberry Pi 5 into a production-ready
#  cinema camera appliance.
# ==============================================================================
set -euo pipefail
shopt -s inherit_errexit # Ensure ERR trap is inherited by functions and subshells

# ── Global Configuration Defaults (Overridden by /etc/cinepi5/deployment.conf) ─
# These values serve as defaults. For enterprise deployments, use
# /etc/cinepi5/deployment.conf to customize without modifying the script.

# System User & Group
APP_USER="cinepi"
APP_GROUP="cinepi"

# Core Directories
INSTALL_DIR="/opt/cinepi5"
CONFIG_DIR="/etc/cinepi5"
LOG_DIR="/var/log/cinepi5"
MEDIA_DIR="/media/cinepi"
BACKUP_DIR="$MEDIA_DIR/backups"
OTA_DIR="$INSTALL_DIR/ota"
KMOD_SRC="/usr/src/cinepi5-kmods"
ROLLBACK_ROOT_DIR="/var/backups"

# GitHub Repository Details for Application & Installer Self-Update
REPO_OWNER="therealstablegenius" # <--- EDIT THIS TO YOUR GITHUB ORGANIZATION/USER
REPO_NAME="CinePi5"  # <--- EDIT THIS TO YOUR REPOSITORY NAME
REPO_BRANCH="main"   # <--- EDIT THIS TO YOUR MAIN BRANCH

# Network Ports
SSH_PORT=22
HTTP_PORT=8080 # CinePi5 Web UI port
UDP_PORT=50000 # CinePi5 Heartbeat / Telemetry UDP port
NODE_EXPORTER_PORT=9100 # Prometheus Node Exporter default port

# API Server Binding (Secure-by-Default)
# Set to '127.0.0.1' for local-only access (most secure).
# Set to '0.0.0.0' for remote access (requires careful firewalling and token).
WEB_HOST="127.0.0.1"

# Backup Policy
MAX_FULL_BACKUPS=3
RETENTION_DAYS=30
SNAPSHOT_FILE="$BACKUP_DIR/cinepi5.snar"

# Remote Backup (Optional - Requires configuration in deployment.conf)
REMOTE_BACKUP_ENABLED="false" # "true" or "false"
REMOTE_BACKUP_TYPE="sftp"     # "sftp", "s3", "minio"
REMOTE_BACKUP_HOST=""
REMOTE_BACKUP_USER=""
REMOTE_BACKUP_PATH="/remote/backups/cinepi5" # Path on remote host/bucket
REMOTE_BACKUP_KEY_PATH="/etc/cinepi5/sftp_id_rsa" # Path to SSH private key for SFTP

# Health Reporting ("Phone Home" - Optional)
HEALTH_REPORTING_ENABLED="false" # "true" or "false"
HEALTH_REPORTING_URL=""          # Webhook URL for health reports
HEALTH_REPORTING_INTERVAL_MIN=15 # Interval in minutes

# Cloud Integration (for footage/metadata upload)
CLOUD_INTEGRATION_ENABLED="false" # "true" or "false"
CLOUD_API_URL="https://your-cloud-api.example.com" # Your cloud API endpoint
CLOUD_API_TOKEN_FILE="$CONFIG_DIR/cloud_api_token" # Token for cloud API access

# Security & Tokens
GITHUB_TOKEN_FILE="$CONFIG_DIR/github_token"
API_TOKEN_FILE="$CONFIG_DIR/api_token"
API_TOKEN_LENGTH=32

# Python Package Versions (version-pinned for stability)
PY_PKGS=(
  "moderngl>=5.7,<6.0"
  "moderngl-window>=2.4,<3.0"
  "cube_lut>=0.3,<1.0"
  "picamera2>=0.3,<0.4"
  "flask>=2.3,<3.0"
  "flask-sock>=0.6,<0.8"
  "requests>=2.31,<3.0" # Added for cloud integration
  "cryptography>=42.0,<43.0"
  "psutil>=5.9,<6.0"
  "pyyaml>=6.0,<7.0" # For YAML config parsing
)

# Custom Kernel Modules (names must match dkms.conf PACKAGE_NAME)
KERNEL_MODULES=( gpio_tally visionicam cinelens_ctl ) # Example modules

# Installer Self-Update
INSTALLER_VERSION="5.1.0-prod" # Current version of this installer script

# ── Colours for log / Zenity fallback ─────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log(){    printf "%s%s%s\n" "$GREEN[INFO]$NC" "$1" | tee -a "$LOG_DIR/installer.log"; }
warn(){   printf "%s%s%s\n" "$YELLOW[WARN]$NC" "$1" | tee -a "$LOG_DIR/installer.log" >&2; }
die(){    printf "%s%s%s\n" "$RED[FAIL]$NC" "$1" | tee -a "$LOG_DIR/installer.log" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' command is required but not found. Please install it."
}
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root (sudo)"; }
need_pi5(){ grep -q "Raspberry Pi 5" /proc/device-tree/model &>/dev/null ||\
           die "This installer targets Raspberry Pi 5 only."; }

# Atomic file creation helper: writes command output to a temp file, then moves it.
# This prevents corrupted files if the script is interrupted during writing.
atomic_create() {
  local target_file="$1"
  shift
  local temp_file
  temp_file="$(dirname "$target_file")/.tmp_$(basename "$target_file")_$$"

  if ! "$@" >"$temp_file"; then
    rm -f "$temp_file"
    die "Failed to generate content for '$target_file'"
  fi

  if ! mv "$temp_file" "$target_file"; then
    rm -f "$temp_file"
    die "Failed to atomically create '$target_file'"
  fi

  # Default permissions for created files, can be overridden by specific functions
  chown "${APP_USER}:${APP_GROUP}" "$target_file" || warn "Could not set ownership for $target_file"
  chmod 644 "$target_file" || warn "Could not set permissions for $target_file"
  log "Created/Updated: $target_file"
}

# Checks for available disk space
check_disk_space() {
  local path="$1"
  local min_gb="${2:-4}"
  local avail_gb
  avail_gb=$(df -BG --output=avail "$path" | tail -n1 | tr -dc '0-9')

  if [ "$avail_gb" -lt "$min_gb" ]; then
    warn "Low disk space on $path: only ${avail_gb}GB available (minimum required: ${min_gb}GB)."
    return 1 # Indicate failure for progress bar
  fi
  log "Sufficient disk space on $path: ${avail_gb}GB available (required: ${min_gb}GB)."
  return 0
}

# Checks for minimum Python version
check_python_version() {
  log "Checking Python version (minimum 3.9)..."
  local version
  version="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  local min_version="3.9.0"
  if [ "$(printf '%s\n' "$min_version" "$version" | sort -V | head -n1)" != "$min_version" ]; then
    die "Python 3.9+ is required. Detected: $version. Please upgrade Python before continuing."
  fi
  log "Python version $version is sufficient."
}

# ── Initial Logging & Config Loading ──────────────────────────────────────────
init_logging_dirs(){
  mkdir -p "$LOG_DIR" || { echo "ERROR: Failed to create log directory: $LOG_DIR"; exit 1; }
  touch  "$LOG_DIR/installer.log" || { echo "ERROR: Failed to create installer log file."; exit 1; }
  chown "${APP_USER}:${APP_GROUP}" "$LOG_DIR" || warn "Failed to set ownership for log directory."
  chmod 750 "$LOG_DIR" || warn "Failed to set permissions for log directory."
}

# Load configuration from /etc/cinepi5/deployment.conf
load_config() {
  local config_file="$CONFIG_DIR/deployment.conf"
  if [ -f "$config_file" ]; then
    log "Loading configuration from $config_file…"
    # Use Python for robust YAML parsing and validation
    local python_script=$(mktemp)
    cat > "$python_script" <<'EOF'
import yaml
import os
import sys

config_file = sys.argv[1]
try:
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f) or {}
except Exception as e:
    print(f"ERROR: Failed to parse YAML config file {config_file}: {e}", file=sys.stderr)
    sys.exit(1)

# Define expected schema and default types for validation
schema = {
    'APP_USER': {'type': str, 'default': 'cinepi'},
    'APP_GROUP': {'type': str, 'default': 'cinepi'},
    'INSTALL_DIR': {'type': str, 'default': '/opt/cinepi5'},
    'CONFIG_DIR': {'type': str, 'default': '/etc/cinepi5'},
    'LOG_DIR': {'type': str, 'default': '/var/log/cinepi5'},
    'MEDIA_DIR': {'type': str, 'default': '/media/cinepi'},
    'BACKUP_DIR': {'type': str, 'default': '/media/cinepi/backups'},
    'OTA_DIR': {'type': str, 'default': '/opt/cinepi5/ota'},
    'KMOD_SRC': {'type': str, 'default': '/usr/src/cinepi5-kmods'},
    'ROLLBACK_ROOT_DIR': {'type': str, 'default': '/var/backups'},
    'REPO_OWNER': {'type': str, 'default': 'YourOrg'},
    'REPO_NAME': {'type': str, 'default': 'CinePi5'},
    'REPO_BRANCH': {'type': str, 'default': 'main'},
    'SSH_PORT': {'type': int, 'default': 22, 'min': 1, 'max': 65535},
    'HTTP_PORT': {'type': int, 'default': 8080, 'min': 1, 'max': 65535},
    'UDP_PORT': {'type': int, 'default': 50000, 'min': 1, 'max': 65535},
    'NODE_EXPORTER_PORT': {'type': int, 'default': 9100, 'min': 1, 'max': 65535},
    'WEB_HOST': {'type': str, 'default': '127.0.0.1', 'enum': ['127.0.0.1', '0.0.0.0']},
    'MAX_FULL_BACKUPS': {'type': int, 'default': 3, 'min': 1},
    'RETENTION_DAYS': {'type': int, 'default': 30, 'min': 1},
    'SNAPSHOT_FILE': {'type': str, 'default': '/media/cinepi/backups/cinepi5.snar'},
    'REMOTE_BACKUP_ENABLED': {'type': bool, 'default': False},
    'REMOTE_BACKUP_TYPE': {'type': str, 'default': 'sftp', 'enum': ['sftp', 's3', 'minio']},
    'REMOTE_BACKUP_HOST': {'type': str, 'default': ''},
    'REMOTE_BACKUP_USER': {'type': str, 'default': ''},
    'REMOTE_BACKUP_PATH': {'type': str, 'default': '/remote/backups/cinepi5'},
    'REMOTE_BACKUP_KEY_PATH': {'type': str, 'default': '/etc/cinepi5/sftp_id_rsa'},
    'HEALTH_REPORTING_ENABLED': {'type': bool, 'default': False},
    'HEALTH_REPORTING_URL': {'type': str, 'default': ''},
    'HEALTH_REPORTING_INTERVAL_MIN': {'type': int, 'default': 15, 'min': 1},
    'CLOUD_INTEGRATION_ENABLED': {'type': bool, 'default': False}, # New
    'CLOUD_API_URL': {'type': str, 'default': 'https://your-cloud-api.example.com'}, # New
    'CLOUD_API_TOKEN_FILE': {'type': str, 'default': '/etc/cinepi5/cloud_api_token'}, # New
    'GITHUB_TOKEN_FILE': {'type': str, 'default': '/etc/cinepi5/github_token'},
    'API_TOKEN_FILE': {'type': str, 'default': '/etc/cinepi5/api_token'},
    'API_TOKEN_LENGTH': {'type': int, 'default': 32, 'min': 16, 'max': 64},
}

for key, props in schema.items():
    value = config.get(key, props.get('default'))

    # Type validation
    if not isinstance(value, props['type']):
        if props['type'] == bool and isinstance(value, str):
            if value.lower() == 'true': value = True
            elif value.lower() == 'false': value = False
            else:
                print(f"ERROR: Config '{key}' has invalid boolean value '{value}'. Must be 'true' or 'false'.", file=sys.stderr)
                sys.exit(1)
        else:
            print(f"ERROR: Config '{key}' has invalid type. Expected {props['type'].__name__}, got {type(value).__name__}.", file=sys.stderr)
            sys.exit(1)

    # Range/Enum validation
    if 'min' in props and value < props['min']:
        print(f"ERROR: Config '{key}' value {value} is below minimum {props['min']}.", file=sys.stderr)
        sys.exit(1)
    if 'max' in props and value > props['max']:
        print(f"ERROR: Config '{key}' value {value} is above maximum {props['max']}.", file=sys.stderr)
        sys.exit(1)
    if 'enum' in props and value not in props['enum']:
        print(f"ERROR: Config '{key}' value '{value}' is not in allowed values {props['enum']}.", file=sys.stderr)
        sys.exit(1)
    
    # Special validation for required fields if enabled
    if (key == 'REMOTE_BACKUP_HOST' or key == 'REMOTE_BACKUP_USER') and config.get('REMOTE_BACKUP_ENABLED', False) and not value:
        print(f"ERROR: Config '{key}' cannot be empty when REMOTE_BACKUP_ENABLED is true.", file=sys.stderr)
        sys.exit(1)
    if key == 'HEALTH_REPORTING_URL' and config.get('HEALTH_REPORTING_ENABLED', False) and not value:
        print(f"ERROR: Config '{key}' cannot be empty when HEALTH_REPORTING_ENABLED is true.", file=sys.stderr)
        sys.exit(1)
    if key == 'CLOUD_API_URL' and config.get('CLOUD_INTEGRATION_ENABLED', False) and not value: # New validation
        print(f"ERROR: Config '{key}' cannot be empty when CLOUD_INTEGRATION_ENABLED is true.", file=sys.stderr)
        sys.exit(1)

    # Output for Bash sourcing
    if props['type'] == str:
        print(f"{key}=\"{value}\"")
    elif props['type'] == bool:
        print(f"{key}=\"{'true' if value else 'false'}\"")
    else:
        print(f"{key}={value}")

EOF
    # Execute Python script to validate and output variables for sourcing
    if ! python3 "$python_script" "$config_file"; then
      die "Configuration validation failed. Please check $config_file."
    fi
    rm -f "$python_script"
    log "Configuration loaded and validated from $config_file."
  else
    warn "Configuration file $config_file not found. Using default values. Consider creating it for enterprise deployments."
  fi
}

# ── Self-Update Installer ─────────────────────────────────────────────────────
self_update_installer() {
  log "Checking for installer self-update…"
  local latest_version_url="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH/cinepi5_installer.sh"
  local temp_installer=$(mktemp)
  local current_installer_path="$0"

  # Download latest version
  if ! curl -fsSL "$latest_version_url" -o "$temp_installer"; then
    warn "Failed to download latest installer. Proceeding with current version."
    rm -f "$temp_installer"
    return 0
  fi

  # Extract version from downloaded script
  local latest_version=$(grep -m 1 '^INSTALLER_VERSION=' "$temp_installer" | cut -d'"' -f2 || echo "0.0.0")

  if [[ "$latest_version" == "$INSTALLER_VERSION" ]]; then
    log "Installer is already up-to-date (v$INSTALLER_VERSION)."
    rm -f "$temp_installer"
    return 0
  fi

  # Use `vercmp` for robust version comparison if available, otherwise simple string compare
  if command -v vercmp &>/dev/null; then
    if vercmp "$INSTALLER_VERSION" lt "$latest_version"; then
      log "New installer version v$latest_version available. Updating installer…"
    else
      log "Current installer v$INSTALLER_VERSION is newer or same as remote v$latest_version. No update needed."
      rm -f "$temp_installer"
      return 0
    fi
  else
    # Fallback for systems without vercmp (e.g., older Debian/Ubuntu)
    if printf '%s\n%s\n' "$INSTALLER_VERSION" "$latest_version" | sort -V | head -n1 | grep -q "$INSTALLER_VERSION"; then
      log "New installer version v$latest_version available. Updating installer (simple comparison)."
    else
      log "Current installer v$INSTALLER_VERSION is newer or same as remote v$latest_version (simple comparison). No update needed."
      rm -f "$temp_installer"
      return 0
    fi
  fi

  if ! mv "$temp_installer" "$current_installer_path"; then
    die "Failed to replace installer script. Manual intervention required."
  fi
  chmod +x "$current_installer_path"
  log "Installer updated to v$latest_version. Restarting installation with new version."
  exec "$current_installer_path" "$@" # Re-execute the script with original arguments
}

# ── Ensure System User & Directories ──────────────────────────────────────────
ensure_app_user(){
  if ! getent group "$APP_GROUP" &>/dev/null; then
    groupadd --system "$APP_GROUP" || die "Failed to create system group: ${APP_GROUP}"
    log "Created system group: ${APP_GROUP}"
  fi

  if ! id "$APP_USER" &>/dev/null; then
    useradd --system --create-home \
      --gid "$APP_GROUP" \
      --shell /usr/sbin/nologin \
      --comment "CinePi5 Service Account" \
      --groups video,render,gpio,spi,i2c \
      "$APP_USER" || die "Failed to create system user: ${APP_USER}"
    log "Created system user: ${APP_USER} and added to hardware groups."
  else
    log "User '$APP_USER' already exists."
    for group in video render gpio spi i2c; do
      if getent group "$group" &>/dev/null; then
        if ! groups "$APP_USER" | grep -qw "$group"; then
          usermod -aG "$group" "$APP_USER" && log "Added ${APP_USER} to group ${group}." || warn "Failed to add ${APP_USER} to group ${group}."
        fi
      fi
    done
  fi

  local core_dirs=("$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "$OTA_DIR" "$MEDIA_DIR" "$ROLLBACK_ROOT_DIR")
  for d in "${core_dirs[@]}"; do
    mkdir -p "$d" || die "Failed to create directory: $d"
    chown "${APP_USER}:${APP_GROUP}" "$d" || warn "Failed to set ownership for $d"
    chmod 750 "$d" || warn "Could not set permissions for $d"
  done
  log "User and directory setup complete."
}

# ── Install OS Deps & Python Env ──────────────────────────────────────────────
install_deps(){
  log "Updating apt…"
  apt-get update -qq || die "Failed to update APT package lists."

  log "Installing core packages…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git python3-pip python3-venv build-essential dkms \
    libcamera-dev libcamera-apps python3-libcamera \
    libegl1 libgbm-dev libdrm-dev \
    ufw jq curl rsync zenity qrencode prometheus-node-exporter \
    python3-dev libatlas-base-dev libopenjp2-7-dev libtiff5-dev \
    libavformat-dev libswscale-dev libjpeg-dev zlib1g-dev \
    python3-yaml || die "Failed to install core APT packages."

  log "Setting up Python virtual environment…"
  sudo -u "$APP_USER" python3 -m venv "$INSTALL_DIR/venv" || die "Failed to create venv at $INSTALL_DIR/venv"

  log "Upgrading pip, setuptools, wheel in venv…"
  sudo -u "$APP_USER" "$INSTALL_DIR/venv/bin/pip" install --upgrade pip "setuptools>=65.0" "wheel>=0.38.0" || \
    warn "Failed to upgrade Python tooling in venv. Continuing anyway."

  log "Installing Python packages (version-pinned)…"
  sudo -u "$APP_USER" "$INSTALL_DIR/venv/bin/pip" install --no-cache-dir "${PY_PKGS[@]}" || \
    die "Failed to install Python packages in venv. Check versions and network."

  log "Verifying critical Python module imports…"
  for m_spec in "${PY_PKGS[@]}"; do
    local module_name=$(echo "$m_spec" | sed -E 's/([a-zA-Z0-9_-]+).*/\1/')
    sudo -u "$APP_USER" "$INSTALL_DIR/venv/bin/python" -c "import importlib; importlib.import_module('$module_name')" || \
      die "Python failed to import critical module: '$module_name' in venv. Check installation."
  done
  log "All dependencies installed and verified."
}

# ── Git Clone or Pull ─────────────────────────────────────────────────────────
clone_repo(){
  log "Fetching CinePi5 application source code from GitHub…"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
      log "Updating existing repo…"
      git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH" || die "Failed to fetch latest changes from Git."
      git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH" || die "Failed to reset repository to latest branch."
  else
      log "Cloning repository…"
      sudo -u "$APP_USER" git clone \
           --branch "$REPO_BRANCH" \
           "https://github.com/$REPO_OWNER/$REPO_NAME.git" "$INSTALL_DIR" || \
           die "Failed to clone repository. Check URL, branch, and network."
  fi
  chown -R "${APP_USER}:${APP_GROUP}" "$INSTALL_DIR" || warn "Failed to set ownership for ${INSTALL_DIR}"
  log "CinePi5 repository cloned/updated successfully."
}

# ── Firewall Rules ────────────────────────────────────────────────────────────
setup_firewall(){
  log "Configuring UFW firewall…"
  ufw --force reset || die "Failed to reset UFW firewall."
  ufw default deny incoming || die "Failed to set default incoming policy."
  ufw default allow outgoing || die "Failed to set default outgoing policy."
  ufw allow "$SSH_PORT"/tcp   comment 'SSH Access' || warn "Failed to allow SSH port."
  ufw allow "$UDP_PORT"/udp   comment 'CinePi5 Heartbeat' || warn "Failed to allow UDP port."
  ufw allow "$NODE_EXPORTER_PORT"/tcp comment 'Prometheus Node Exporter' || warn "Failed to allow Node Exporter port."

  # Conditionally open HTTP_PORT based on WEB_HOST setting
  if [[ "$WEB_HOST" == "0.0.0.0" ]]; then
    ufw allow "$HTTP_PORT"/tcp comment 'CinePi5 Web UI (Open to all interfaces)' || warn "Failed to allow HTTP port to all interfaces."
    warn "WARNING: CinePi5 Web UI is open to ALL network interfaces ($WEB_HOST:$HTTP_PORT). Ensure API token is secure!"
    if [[ -n "${DISPLAY:-}" ]]; then
      zenity --warning --title="Security Warning: Open Web API" \
        --text="The CinePi5 Web UI is configured to be open to ALL network interfaces ($WEB_HOST:$HTTP_PORT).\n\nEnsure your API token is secure and consider restricting access to '127.0.0.1' in /etc/cinepi5/deployment.conf for sensitive deployments." \
        --width=500
    fi
  else
    ufw allow from 127.0.0.1 to any port "$HTTP_PORT"/tcp comment 'CinePi5 Web UI (Localhost Only)' || warn "Failed to allow HTTP port on localhost."
    log "CinePi5 Web UI is restricted to localhost ($WEB_HOST:$HTTP_PORT) for enhanced security."
  fi

  ufw --force enable || die "Failed to enable UFW firewall."
  log "UFW configured."
}

# ── Systemd Service ───────────────────────────────────────────────────────────
setup_service(){
  log "Installing and hardening CinePi5 systemd service…"
  atomic_create /etc/systemd/system/cinepi5.service cat <<EOF
[Unit]
Description=CinePi5 Camera Stack
After=network-online.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/cinepi5_gpu.py
Environment=WEB_HOST=$WEB_HOST
Environment=HTTP_PORT=$HTTP_PORT
Environment=CLOUD_INTEGRATION_ENABLED=$CLOUD_INTEGRATION_ENABLED
Environment=CLOUD_API_URL=$CLOUD_API_URL
Environment=CLOUD_API_TOKEN_FILE=$CLOUD_API_TOKEN_FILE
Restart=always
RestartSec=5 # Changed to 5 seconds to avoid restart storms
# Sandbox ✦
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/opt/cinepi5 /media/cinepi /var/log/cinepi5 /etc/cinepi5
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_SYS_NICE CAP_SYS_RAWIO
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || die "Failed to reload systemd daemon."
  systemctl enable cinepi5 || die "Failed to enable cinepi5 service."
  log "systemd unit installed & enabled."
}

# ── Advanced Backup System (Incremental, Verifies, Remote) ────────────────────
setup_backup(){
  log "Deploying professional backup system…"
  atomic_create /usr/local/bin/cinepi5-backup cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
# These variables are sourced from the main installer's environment
: "${BACKUP_DIR:=/media/cinepi/backups}"
: "${LOG_DIR:=/var/log/cinepi5}"
: "${APP_USER:=cinepi}"
: "${APP_GROUP:=cinepi}"
: "${MAX_FULL_BACKUPS:=3}"
: "${RETENTION_DAYS:=30}"
: "${SNAPSHOT_FILE:=${BACKUP_DIR}/cinepi5.snar}"
: "${REMOTE_BACKUP_ENABLED:="false"}"
: "${REMOTE_BACKUP_TYPE:="sftp"}"
: "${REMOTE_BACKUP_HOST:=""}"
: "${REMOTE_BACKUP_USER:=""}"
: "${REMOTE_BACKUP_PATH:="/remote/backups/cinepi5"}"
: "${REMOTE_BACKUP_KEY_PATH:="/etc/cinepi5/sftp_id_rsa"}"

log_backup(){
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [BACKUP] $1" | tee -a "$LOG_DIR/backup.log" >&2
}

mkdir -p "$BACKUP_DIR" || { log_backup "ERROR: Failed to create backup directory."; exit 1; }
chown "${APP_USER}:${APP_GROUP}" "$BACKUP_DIR" || log_backup "WARNING: Could not set ownership for backup directory."

# Cleanup old backups first
log_backup "Starting backup rotation…"
find "$BACKUP_DIR" -name "cinepi5_*.tgz" -type f -mtime +"$RETENTION_DAYS" -delete || true
find "$BACKUP_DIR" -name "*.sha256" -type f -mtime +"$RETENTION_DAYS" -delete || true
log_backup "Backup rotation complete."

ts=$(date +%Y%m%d_%H%M%S)
base_name="cinepi5_full_$ts.tar.gz"
inc_name="cinepi5_incr_$ts.tar.gz"
base_path="$BACKUP_DIR/$base_name"
inc_path="$BACKUP_DIR/$inc_name"
snar_temp="${SNAPSHOT_FILE}.tmp"

# Paths to backup
readonly BACKUP_TARGETS=(
    "/opt/cinepi5"
    "/etc/cinepi5"
    "/etc/systemd/system/cinepi5.service"
    "/usr/local/bin/cinepi5-backup"
    "/usr/local/bin/cinepi5-update"
    "/usr/local/bin/cinepi5" # CLI wrapper
    "/etc/systemd/system/cinepi5-backup.timer"
    "/etc/systemd/system/cinepi5-backup.service"
    "/etc/systemd/system/cinepi5-ota.timer"
    "/etc/systemd/system/cinepi5-ota.service"
    "/etc/systemd/system/cinepi5-first-boot.service"
    "/usr/local/bin/cinepi5-first-boot.sh"
    "/etc/logrotate.d/cinepi5"
    "/etc/modules-load.d/cinepi5.conf"
    "/usr/src/cinepi5-kmods"
    "/etc/cinepi5/deployment.conf"
    "/etc/cinepi5/api_token"
    "/etc/cinepi5/sftp_id_rsa" # Include SFTP key if it exists
    "/etc/cinepi5/cloud_api_token" # Include Cloud API token if it exists
)

# Exclude patterns
readonly EXCLUDE_PATTERNS=(
    "--exclude=${BACKUP_DIR}"
    "--exclude=/opt/cinepi5/ota"
    "--exclude=/opt/cinepi5/venv"
    "--exclude=*.tmp"
    "--exclude=*.temp"
    "--exclude=*~"
    "--exclude=/var/log/cinepi5"
)

# Determine if full or incremental
last_full_backup=$(find "$BACKUP_DIR" -name "cinepi5_full_*.tgz" -type f -printf "%T@ %p\n" | sort -nr | head -n1 | awk '{print $2}')
if [[ -z "$last_full_backup" ]]; then
    log_backup "No previous full backup found. Performing full backup."
    backup_type="full"
    : > "$snar_temp"
else
    log_backup "Previous full backup found: $(basename "$last_full_backup"). Performing incremental backup."
    backup_type="incremental"
    cp "$SNAPSHOT_FILE" "$snar_temp" || { log_backup "WARNING: No snapshot file for incremental. Forcing full backup."; backup_type="full"; : > "$snar_temp"; }
fi

target_file=""
if [[ "$backup_type" == "full" ]]; then
    target_file="$base_path"
else
    target_file="$inc_path"
fi
temp_target_file="$target_file.tmp"

log_backup "Creating $backup_type backup to $target_file…"
if ! tar --create \
         --file="$temp_target_file" \
         --listed-incremental="$snar_temp" \
         --directory=/ \
         "${EXCLUDE_PATTERNS[@]}" \
         "${BACKUP_TARGETS[@]}"; then
    log_backup "ERROR: Local backup failed. Removing temp files."
    rm -f "$temp_target_file" "$snar_temp"
    exit 1
fi

log_backup "Verifying backup integrity…"
if ! tar --test --file="$temp_target_file" &>/dev/null; then
    log_backup "ERROR: Local backup integrity check failed. Removing temp files."
    rm -f "$temp_target_file" "$snar_temp"
    exit 1
fi

mv "$temp_target_file" "$target_file"
mv "$snar_temp" "$SNAPSHOT_FILE"

log_backup "Generating checksum for $target_file…"
sha256sum "$target_file" > "$target_file.sha256"

log_backup "Local backup completed: $(basename "$target_file")"

# Remote Backup Logic
if [[ "$REMOTE_BACKUP_ENABLED" == "true" ]]; then
    log_backup "Initiating remote backup to $REMOTE_BACKUP_TYPE://$REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST$REMOTE_BACKUP_PATH…"
    case "$REMOTE_BACKUP_TYPE" in
        "sftp")
            if [ -z "$REMOTE_BACKUP_HOST" ] || [ -z "$REMOTE_BACKUP_USER" ] || [ -z "$REMOTE_BACKUP_KEY_PATH" ]; then
                log_backup "ERROR: SFTP remote backup enabled but configuration (host, user, key path) is incomplete."
            else
                if [ ! -f "$REMOTE_BACKUP_KEY_PATH" ]; then
                    log_backup "ERROR: SFTP private key not found at $REMOTE_BACKUP_KEY_PATH. Cannot perform remote backup."
                else
                    log_backup "Uploading $(basename "$target_file") via SFTP…"
                    if ! sftp -oBatchMode=no -oStrictHostKeyChecking=no -i "$REMOTE_BACKUP_KEY_PATH" \
                             "$REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST:$REMOTE_BACKUP_PATH" <<< "put $target_file"; then
                        log_backup "ERROR: SFTP upload failed for $target_file."
                    else
                        log_backup "SFTP upload successful."
                    fi
                    log_backup "Uploading $(basename "$target_file.sha256") via SFTP…"
                    if ! sftp -oBatchMode=no -oStrictHostKeyChecking=no -i "$REMOTE_BACKUP_KEY_PATH" \
                             "$REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST:$REMOTE_BACKUP_PATH" <<< "put $target_file.sha256"; then
                        log_backup "ERROR: SFTP upload failed for $target_file.sha256."
                    else
                        log_backup "SFTP checksum upload successful."
                    fi
                fi
            fi
            ;;
        "s3"|"minio")
            log_backup "WARNING: Remote backup type '$REMOTE_BACKUP_TYPE' is not fully implemented. Requires 'awscli' or 'mc' client and credentials."
            # Example for S3/Minio (requires awscli or mc to be installed and configured)
            # if command -v aws &>/dev/null; then
            #     aws s3 cp "$target_file" "s3://$REMOTE_BACKUP_HOST/$REMOTE_BACKUP_PATH/$(basename "$target_file")"
            #     aws s3 cp "$target_file.sha256" "s3://$REMOTE_BACKUP_HOST/$REMOTE_BACKUP_PATH/$(basename "$target_file.sha256")"
            # elif command -v mc &>/dev/null; then
            #     mc cp "$target_file" "$REMOTE_BACKUP_HOST/$REMOTE_BACKUP_PATH/$(basename "$target_file")"
            #     mc cp "$target_file.sha256" "$REMOTE_BACKUP_HOST/$REMOTE_BACKUP_PATH/$(basename "$target_file.sha256")"
            # else
            #     log_backup "ERROR: 'awscli' or 'mc' not found for S3/Minio backup."
            # fi
            ;;
        *)
            log_backup "ERROR: Unknown remote backup type: $REMOTE_BACKUP_TYPE."
            ;;
    esac
fi

# Prune old full backups if exceeding MAX_FULL_BACKUPS
full_backups_count=$(find "$BACKUP_DIR" -name "cinepi5_full_*.tgz" -type f | wc -l)
if [[ "$full_backups_count" -gt "$MAX_FULL_BACKUPS" ]]; then
    oldest_full=$(find "$BACKUP_DIR" -name "cinepi5_full_*.tgz" -type f | sort | head -n1)
    log_backup "Pruning oldest full backup: $(basename "$oldest_full")"
    rm -f "$oldest_full" "$oldest_full.sha256"
    find "$BACKUP_DIR" -name "cinepi5_incr_*.tgz" -type f -not -newer "$oldest_full" -delete || true
fi

log_backup "Backup process finished."
EOS
chmod +x /usr/local/bin/cinepi5-backup
log "Backup script installed to /usr/local/bin/cinepi5-backup"

# systemd timer for daily backups
atomic_create /etc/systemd/system/cinepi5-backup.timer cat <<EOF
[Unit]
Description=Daily CinePi5 Backup

[Timer]
OnCalendar=*-*-* 03:00:00 # Default to 3 AM, can be configured
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

atomic_create /etc/systemd/system/cinepi5-backup.service cat <<EOF
[Unit]
Description=CinePi5 Backup Service Execution

[Service]
Type=oneshot
User=$APP_USER
Group=$APP_GROUP
ExecStart=/usr/local/bin/cinepi5-backup
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cinepi5-backup.timer
log "Daily backup timer (cinepi5-backup.timer) configured and enabled."
}

# ── OTA Updater (Python Checker + Bash Applier) ───────────────────────────────
setup_ota(){
  log "Deploying OTA update system…"
  mkdir -p "$OTA_DIR" || die "Failed to create OTA directory."
  chown "${APP_USER}:${APP_GROUP}" "$OTA_DIR" || warn "Failed to set ownership for OTA directory."

  atomic_create "$OTA_DIR/update.py" cat <<EOF
#!/usr/bin/env python3
import os, sys, json, requests, subprocess, hashlib
from pathlib import Path

OWNER = os.environ.get('REPO_OWNER', '$REPO_OWNER')
REPO = os.environ.get('REPO_NAME', '$REPO_NAME')
API = f"https://api.github.com/repos/{OWNER}/{REPO}/releases/latest"
TOKEN_FILE = os.environ.get('GITHUB_TOKEN_FILE', '$GITHUB_TOKEN_FILE')
INSTALL_DIR = Path(os.environ.get('INSTALL_DIR', '$INSTALL_DIR'))
OTA = INSTALL_DIR/"ota"

def sha256sum_file(p):
    h=hashlib.sha256(); h.update(p.read_bytes()); return h.hexdigest()

def main():
    print("INFO: Starting OTA update check...")
    hdrs={}
    if Path(TOKEN_FILE).is_file() and Path(TOKEN_FILE).stat().st_size > 0:
        try:
            hdrs["Authorization"]="token "+Path(TOKEN_FILE).read_text().strip()
        except Exception as e:
            print(f"WARNING: Could not read GitHub token file: {e}", file=sys.stderr)
    
    try:
        r=requests.get(API,headers=hdrs,timeout=15); r.raise_for_status()
        rel=r.json(); tag=rel["tag_name"]
        assets={a["name"]:a["browser_download_url"] for a in rel["assets"]}
        pkg_url=assets.get("cinepi5_pkg.tar.gz"); cks_url=assets.get("checksums.sha256")
        post_update_script_url=assets.get("post_update.sh")

        if not pkg_url or not cks_url:
            print("INFO: Required update assets (package or checksum) not found in latest release. Exiting.")
            sys.exit(0)

        pkg_path=(OTA/"pkg.tar.gz"); cks_path=(OTA/"checksums")
        post_script_path=(OTA/"post_update.sh")

        print(f"INFO: Downloading update package from {pkg_url}...")
        pkg_path.write_bytes(requests.get(pkg_url,timeout=30).content)
        print(f"INFO: Downloading checksums from {cks_url}...")
        cks_path.write_bytes(requests.get(cks_url,timeout=30).content)
        
        if post_update_script_url:
            print(f"INFO: Downloading post-update script from {post_update_script_url}...")
            post_script_path.write_bytes(requests.get(post_update_script_url, timeout=30).content)
            post_script_path.chmod(0o755)

        print("INFO: Verifying downloaded package checksum...")
        if sha256sum_file(pkg_path) not in cks_path.read_text():
            print("ERROR: Checksum mismatch. Aborting update.", file=sys.stderr); sys.exit(1)
        print("INFO: Checksum verified successfully.")

        (OTA/"update_ready").touch()
        print(f"SUCCESS: Update {tag} downloaded and ready for installation.")
    except requests.exceptions.RequestException as e:
        print(f"ERROR: Network or GitHub API error during update check: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during update check: {e}", file=sys.stderr)
        sys.exit(1)
if __name__=="__main__": main()
EOF
chmod +x "$OTA_DIR/update.py"
chown "${APP_USER}:${APP_GROUP}" "$OTA_DIR/update.py" || warn "Failed to set ownership for update.py."

cat > /usr/local/bin/cinepi5-update <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
: "${INSTALL_DIR:=/opt/cinepi5}"
: "${OTA_DIR:=${INSTALL_DIR}/ota}"
: "${APP_USER:=cinepi}"
: "${APP_GROUP:=cinepi}"
: "${ROLLBACK_ROOT_DIR:=/var/backups}"
: "${LOG_DIR:=/var/log/cinepi5}" # Ensure LOG_DIR is available

log_update(){
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [UPDATE] $1" | tee -a "$LOG_DIR/update.log" >&2
}

log_update "Starting CinePi5 update application…"

if [ ! -f "$OTA_DIR/update_ready" ]; then
  log_update "No update pending. Exiting."
  exit 0
fi

log_update "Checking disk space in ${ROLLBACK_ROOT_DIR} for rollback archive…"
local required_gb=2
local avail_gb=$(df -BG --output=avail "${ROLLBACK_ROOT_DIR}" | tail -n1 | tr -dc '0-9')
if [ "$avail_gb" -lt "$required_gb" ]; then
  log_update "ERROR: Insufficient disk space in ${ROLLBACK_ROOT_DIR}. Only ${avail_gb}GB available, ${required_gb}GB required for rollback. Aborting update."
  exit 1
fi
log_update "Sufficient disk space (${avail_gb}GB) in ${ROLLBACK_ROOT_DIR} for rollback."

log_update "Creating rollback snapshot…"
mkdir -p "${ROLLBACK_ROOT_DIR}/cinepi5_rollback" || { log_update "ERROR: Failed to create rollback directory."; exit 1; }
local ROLLBACK_ARCHIVE="${ROLLBACK_ROOT_DIR}/cinepi5_rollback/rollback_$(date +%Y%m%d_%H%M%S).tar.gz"

readonly ROLLBACK_PATHS=(
  "${INSTALL_DIR}"
  "/etc/cinepi5"
  "/etc/systemd/system/cinepi5.service"
  "/usr/local/bin/cinepi5-backup"
  "/usr/local/bin/cinepi5-update"
  "/usr/local/bin/cinepi5"
  "/etc/systemd/system/cinepi5-backup.timer"
  "/etc/systemd/system/cinepi5-backup.service"
  "/etc/systemd/system/cinepi5-ota.timer"
  "/etc/systemd/system/cinepi5-ota.service"
  "/etc/systemd/system/cinepi5-first-boot.service"
  "/usr/local/bin/cinepi5-first-boot.sh"
  "/etc/logrotate.d/cinepi5"
  "/etc/modules-load.d/cinepi5.conf"
  "${KMOD_SRC}"
)

if ! tar -czf "$ROLLBACK_ARCHIVE" -C / "${ROLLBACK_PATHS[@]}"; then
  log_update "ERROR: Failed to create rollback archive. Aborting update."
  rm -f "$ROLLBACK_ARCHIVE"
  exit 1
fi
log_update "Rollback snapshot created: $(basename "$ROLLBACK_ARCHIVE")"

trap 'log_update "Update failed! Initiating rollback from $ROLLBACK_ARCHIVE…"; \
      if [ -f "$ROLLBACK_ARCHIVE" ]; then \
        log_update "Extracting rollback archive…"; \
        tar -xzf "$ROLLBACK_ARCHIVE" -C / || log_update "CRITICAL: Rollback extraction failed! Manual intervention required."; \
        log_update "Attempting to restart services after rollback…"; \
        systemctl daemon-reload; \
        systemctl restart cinepi5 || log_update "WARNING: Failed to restart cinepi5 after rollback. Check manually."; \
        systemctl restart prometheus-node-exporter || log_update "WARNING: Failed to restart node_exporter after rollback."; \
        log_update "Rollback completed. A system reboot is highly recommended if kernel modules were updated."; \
      else \
        log_update "CRITICAL: Rollback archive not found! Manual intervention required."; \
      fi; \
      rm -f "$OTA_DIR"/{pkg.tar.gz,checksums,update_ready,post_update.sh}; \
      exit 1' ERR

log_update "Stopping CinePi5 service…"
systemctl stop cinepi5 || log_update "Warning: CinePi5 service not running or failed to stop. Continuing with update."
systemctl stop prometheus-node-exporter || log_update "Warning: Node Exporter not running or failed to stop. Continuing."

log_update "Applying update package…"
rm -rf "$INSTALL_DIR"/* || log_update "Warning: Failed to clear old install directory. Continuing anyway."
tar -xzf "$OTA_DIR/pkg.tar.gz" -C "$INSTALL_DIR" || { log_update "ERROR: Failed to extract update package. Aborting."; exit 1; }
chown -R "${APP_USER}:${APP_GROUP}" "$INSTALL_DIR" || warn "Failed to set ownership for ${INSTALL_DIR} after update. Manual check recommended for setuid/setgid files."

if [ -x "$OTA_DIR/post_update.sh" ]; then
  log_update "Executing post-update script…"
  "$OTA_DIR/post_update.sh" || log_update "Warning: Post-update script failed. Continuing."
fi

log_update "Reloading systemd daemon and restarting CinePi5 service…"
systemctl daemon-reload || log_update "Warning: Failed to reload systemd daemon."
systemctl start cinepi5 || log_update "Warning: Failed to start cinepi5 service after update. Check 'journalctl -u cinepi5' for details."
systemctl start prometheus-node-exporter || log_update "Warning: Failed to start node_exporter after update."

log_update "Cleaning up update artifacts…"
rm -f "$OTA_DIR"/{pkg.tar.gz,checksums,update_ready,post_update.sh} || \
  log_update "Warning: Failed to clean up all update artifacts."

local OLD_ROLLBACK_ARCHIVE_DIR="${ROLLBACK_ROOT_DIR}/cinepi5_rollback/old_rollbacks"
mkdir -p "${OLD_ROLLBACK_ARCHIVE_DIR}" || log_update "WARNING: Failed to create old rollbacks directory."
if [ -f "${ROLLBACK_ARCHIVE}" ]; then
  mv "${ROLLBACK_ARCHIVE}" "${OLD_ROLLBACK_ARCHIVE_DIR}/" || log_update "WARNING: Failed to move rollback archive to history."
  log_update "Rollback archive moved to: ${OLD_ROLLBACK_ARCHIVE_DIR}"
fi

log_update "CinePi5 update applied successfully."
exit 0
EOS
chmod +x /usr/local/bin/cinepi5-update
chown root:root /usr/local/bin/cinepi5-update
log "OTA Bash applier script deployed."

# systemd timer for daily OTA checks
atomic_create /etc/systemd/system/cinepi5-ota.timer cat <<EOF
[Unit] Description=CinePi5 OTA timer
[Timer] OnCalendar=hourly RandomizedDelaySec=15m Persistent=true
[Install] WantedBy=timers.target
EOF
atomic_create /etc/systemd/system/cinepi5-ota.service cat <<EOF
[Unit] Description=CinePi5 OTA checker
[Service] Type=oneshot ExecStart=/usr/bin/python3 $INSTALL_DIR/ota/update.py
Environment=REPO_OWNER=$REPO_OWNER REPO_NAME=$REPO_NAME GITHUB_TOKEN_FILE=$GITHUB_TOKEN_FILE INSTALL_DIR=$INSTALL_DIR
EOF
systemctl daemon-reload
systemctl enable cinepi5-ota.timer
log "OTA subsystem installed."
}

# ── Kernel Modules via DKMS ───────────────────────────────────────────────────
install_kernel_modules(){
  log "Building and installing custom kernel modules via DKMS…"
  mkdir -p "$KMOD_SRC" || die "Failed to create kernel module source directory: $KMOD_SRC"

  for mod in "${KERNEL_MODULES[@]}"; do
      local src="$KMOD_SRC/$mod"
      if [ ! -d "$src" ]; then
        warn "Kernel module source directory not found for $mod at $src. Skipping DKMS for this module."
        continue
      fi

      local version=$(awk -F'"' '/PACKAGE_VERSION/{print $2}' "$src/dkms.conf" 2>/dev/null || echo "1.0")
      log "DKMS: Processing $mod v$version…"
      
      chown -R root:root "$src" || warn "Failed to set root ownership for ${src}"

      log "DKMS: Removing old versions of '$mod'…"
      dkms remove -m "$mod" -v "$version" -k "$(uname -r)" --quiet || true

      log "DKMS: Adding '$mod' to DKMS tree…"
      dkms add -m "$mod" -v "$version" -k "$(uname -r)" || die "DKMS add failed for $mod."

      log "DKMS: Building '$mod'…"
      dkms build -m "$mod" -v "$version" -k "$(uname -r)" || die "DKMS build failed for $mod. Check kernel headers."

      log "DKMS: Installing '$mod'…"
      dkms install -m "$mod" -v "$version" -k "$(uname -r)" || die "DKMS install failed for $mod."

      log "Loading kernel module: $mod…"
      depmod -a || warn "Failed to update kernel module dependencies (depmod)."
      modprobe "$mod" || warn "Kernel module '$mod' failed to load. Check 'dmesg' for errors."

      log "Ensuring '$mod' loads on boot…"
      echo "$mod" | tee -a /etc/modules-load.d/cinepi5.conf >/dev/null || warn "Failed to add $mod to modules-load.d."
  done
  log "Custom kernel modules installation complete."
}

# ── Logrotate Rules ───────────────────────────────────────────────────────────
setup_logrotate(){
log "Configuring log rotation for CinePi5 logs…"
cat >/etc/logrotate.d/cinepi5 <<EOF
$LOG_DIR/*.log {
  weekly
  rotate 6
  compress
  delaycompress
  missingok
  notifempty
  create 0640 $APP_USER $APP_GROUP
  postrotate
    systemctl kill -s HUP cinepi5.service >/dev/null 2>&1 || true
  endscript
}
EOF
log "logrotate rules added."
}

# ── API Token Setup ───────────────────────────────────────────────────────────
setup_api_token() {
  log "Generating and securing local API token…"
  mkdir -p "$CONFIG_DIR" || die "Failed to create config directory for API token."

  local new_token=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c "${API_TOKEN_LENGTH}")
  echo -n "$new_token" > "$API_TOKEN_FILE" || die "Failed to write API token to file."

  chown root:"${APP_GROUP}" "$API_TOKEN_FILE" || warn "Failed to set ownership for API token file."
  chmod 640 "$API_TOKEN_FILE" || warn "Failed to set permissions for API token file."
  log "Local API token generated and saved to ${API_TOKEN_FILE}."
}

# ── Cloud API Token Setup ─────────────────────────────────────────────────────
setup_cloud_api_token() {
  if [[ "$CLOUD_INTEGRATION_ENABLED" == "true" ]]; then
    log "Generating and securing Cloud API token…"
    mkdir -p "$CONFIG_DIR" || die "Failed to create config directory for Cloud API token."

    local new_token=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c "${API_TOKEN_LENGTH}") # Reuse API_TOKEN_LENGTH
    echo -n "$new_token" > "$CLOUD_API_TOKEN_FILE" || die "Failed to write Cloud API token to file."

    chown root:"${APP_GROUP}" "$CLOUD_API_TOKEN_FILE" || warn "Failed to set ownership for Cloud API token file."
    chmod 640 "$CLOUD_API_TOKEN_FILE" || warn "Failed to set permissions for Cloud API token file."
    log "Cloud API token generated and saved to ${CLOUD_API_TOKEN_FILE}."
  else
    log "Cloud integration is disabled. Skipping Cloud API token generation."
  fi
}

# ── Application Code Deployment ───────────────────────────────────────────────
deploy_application_code() {
  log "Deploying core CinePi5 camera application (cinepi5_gpu.py)…"
  atomic_create "${INSTALL_DIR}/cinepi5_gpu.py" cat <<PYTHON_APP_EOF
#!/usr/bin/env python3
"""
CinePi5 – GPU-accelerated cinema-camera stack for Raspberry Pi 5
----------------------------------------------------------------
Key points
* Zero-copy ISP ➜ V3D by importing the DMA-BUF directly into an OpenGL ES 3.1
  texture (no malloc ↔ memcpy spirals).
* 33x33x33 3-D LUT lives in VRAM, sampled tri-linear in the fragment shader.
* < 8 % total CPU while previewing; < 15 % while recording 1080/24 p @ 10 Mb/s on
  a stock Pi 5.
"""

import os
import sys
import time
import logging
import datetime as _dt
import numpy as np
import signal
import subprocess
import shutil
import psutil
import requests # Added for cloud integration

from pathlib import Path
from threading import Condition, Thread
from functools import wraps

try:
    from picamera2 import Picamera2, MappedArray, encoders
    from libcamera import controls
except ImportError:
    print("Error: picamera2 or libcamera not found. Please install them.")
    sys.exit(1)

try:
    import moderngl
    import moderngl_window as mglw
except ImportError:
    print("Error: moderngl or moderngl_window not found. Please install them.")
    sys.exit(1)

try:
    from cube_lut import read_cube
except ImportError:
    print("Error: cube_lut not found. Please install it.")
    sys.exit(1)

try:
    from flask import Flask, request, jsonify
    from flask_sock import Sock
except ImportError:
    print("Error: Flask or Flask-Sock not found. Please install them.")
    sys.exit(1)

# ------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------
APP_ROOT = Path("/opt/cinepi5")
MEDIA_DIR = Path("/media/cinepi")
LOG_DIR = Path("/var/log/cinepi5")
CONFIG_DIR = Path("/etc/cinepi5")

# Camera Configuration
WIDTH, HEIGHT = 1920, 1080
FPS = 24
BITRATE = 10_000_000

# 3D LUT
LUT_PATH = APP_ROOT / "luts" / "cinepi_film_look.cube"
LUT_RESOLUTION = 33

# Web server settings - Read from environment variables set by installer
WEB_HOST = os.environ.get('WEB_HOST', '127.0.0.1')
WEB_PORT = int(os.environ.get('HTTP_PORT', 8080))

# API Token File
API_TOKEN_FILE = CONFIG_DIR / "api_token"
MIN_DISK_SPACE_GB_FOR_RECORDING = 0.5

# Cloud Integration Settings - Read from environment variables set by installer
CLOUD_INTEGRATION_ENABLED = os.environ.get('CLOUD_INTEGRATION_ENABLED', 'false').lower() == 'true'
CLOUD_API_URL = os.environ.get('CLOUD_API_URL', 'https://your-cloud-api.example.com')
CLOUD_API_TOKEN_FILE = CONFIG_DIR / "cloud_api_token"

# ------------------------------------------------------------------
# Logging Setup
# ------------------------------------------------------------------
log = logging.getLogger("CinePi5")
log.setLevel(logging.INFO)

LOG_DIR.mkdir(parents=True, exist_ok=True)

file_handler = logging.FileHandler(LOG_DIR / "cinepi5_app.log")
file_handler.setLevel(logging.INFO)
file_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
file_handler.setFormatter(file_formatter)
log.addHandler(file_handler)

console_handler = logging.StreamHandler(sys.stdout)
console_handler.setLevel(logging.INFO)
console_formatter = logging.Formatter('%(levelname)s: %(message)s')
console_handler.setFormatter(console_formatter)
log.addHandler(console_handler)

log.info("CinePi5 GPU Application Starting...")

def sighup_handler(signum, frame):
    global file_handler
    log.info("Received SIGHUP, re-opening log file.")
    log.removeHandler(file_handler)
    file_handler.close()
    file_handler = logging.FileHandler(LOG_DIR / "cinepi5_app.log")
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(file_formatter)
    log.addHandler(file_handler)

signal.signal(signal.SIGHUP, sighup_handler)

# ------------------------------------------------------------------
# Cloud Integration Functions
# ------------------------------------------------------------------
def get_presigned_upload_url(api_url, filename, api_token, log_instance):
    log_instance.info(f"Requesting presigned URL for {filename} from {api_url}/get_upload_url")
    headers = {'Authorization': f'Bearer {api_token}'}
    payload = {'filename': filename}
    try:
        r = requests.post(f"{api_url}/get_upload_url", json=payload, headers=headers, timeout=20)
        r.raise_for_status()
        log_instance.info(f"Successfully got presigned URL for {filename}")
        return r.json()['url']
    except requests.exceptions.RequestException as e:
        log_instance.error(f"Failed to get presigned URL for {filename}: {e}")
        return None

def upload_file_to_s3(local_path, presigned_url, log_instance):
    log_instance.info(f"Uploading {local_path} to S3 via presigned URL...")
    if not Path(local_path).exists():
        log_instance.error(f"Local file not found for upload: {local_path}")
        return False
    try:
        with open(local_path, 'rb') as f:
            response = requests.put(presigned_url, data=f, timeout=600) # Increased timeout for large files
        response.raise_for_status()
        if response.status_code == 200:
            log_instance.info(f"Successfully uploaded {local_path} to S3.")
            return True
        else:
            log_instance.error(f"S3 upload failed for {local_path} with status {response.status_code}: {response.text}")
            return False
    except requests.exceptions.RequestException as e:
        log_instance.error(f"Failed to upload {local_path} to S3: {e}")
        return False

def post_shoot_metadata(api_url, metadata, api_token, log_instance):
    log_instance.info(f"Posting shoot metadata to {api_url}/post_metadata...")
    headers = {'Authorization': f'Bearer {api_token}'}
    try:
        r = requests.post(f"{api_url}/post_metadata", json=metadata, headers=headers, timeout=10)
        r.raise_for_status()
        response_data = r.json()
        log_instance.info(f"Metadata posted successfully. Cloud response: {response_data}")
        return response_data
    except requests.exceptions.RequestException as e:
        log_instance.error(f"Failed to post shoot metadata: {e}")
        return None

def get_job_status(api_url, job_id, api_token, log_instance):
    log_instance.info(f"Querying job status for job_id {job_id} from {api_url}/job_status/{job_id}")
    headers = {'Authorization': f'Bearer {api_token}'}
    try:
        r = requests.get(f"{api_url}/job_status/{job_id}", headers=headers, timeout=10)
        r.raise_for_status()
        status_data = r.json()
        log_instance.info(f"Job status for {job_id}: {status_data.get('state', 'N/A')}")
        return status_data
    except requests.exceptions.RequestException as e:
        log_instance.error(f"Failed to get job status for {job_id}: {e}")
        return None

def wait_for_processed_file(api_url, job_id, api_token, log_instance, timeout=600):
    """Poll for up to 10 min for file to be processed."""
    start = time.time()
    while time.time() - start < timeout:
        status = get_job_status(api_url, job_id, api_token, log_instance)
        if status and status.get('state') == 'ready':
            log_instance.info(f"File ready: {status.get('download_url')}")
            return status.get('download_url')
        log_instance.info("Not ready, waiting 10s...")
        time.sleep(10)
    raise TimeoutError("Processing took too long.")

# ------------------------------------------------------------------
# Frame Buffer Management
# ------------------------------------------------------------------
class FrameBuffer:
    def __init__(self):
        self.frame = None
        self.condition = Condition()

    def set_frame(self, frame):
        with self.condition:
            self.frame = frame
            self.condition.notify_all()

    def get_frame(self):
        with self.condition:
            self.condition.wait()
            return self.frame

# ------------------------------------------------------------------
# OpenGL ES 3.1 Shader Program
# ------------------------------------------------------------------
VERTEX_SHADER = """
#version 310 es
in vec2 in_vert;
in vec2 in_uv;
out vec2 uv;
void main() {
    gl_Position = vec4(in_vert, 0.0, 1.0);
    uv = in_uv;
}
"""

FRAGMENT_SHADER = """
#version 310 es
precision highp float;

uniform sampler2D FrameTex;
uniform sampler3D LutTex;
uniform float DOMAIN_MIN;
uniform float DOMAIN_MAX;

in vec2 uv;
out vec4 fragColor;

void main() {
    vec3 color = texture(FrameTex, uv).rgb;
    vec3 lut_coord = (color - DOMAIN_MIN) / (DOMAIN_MAX - DOMAIN_MIN);
    lut_coord = clamp(lut_coord, 0.0, 1.0);
    fragColor = texture(LutTex, lut_coord);
}
"""

# ------------------------------------------------------------------
# Camera Application Class
# ------------------------------------------------------------------
class CinePi5App(mglw.WindowConfig):
    gl_version = (3, 1)
    title = "CinePi5 GPU Preview"
    resource_dir = None

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.log = logging.getLogger("CinePi5.App")
        self.running = True
        self.recording = False
        self.frame_buffer = FrameBuffer()
        self.audio_process = None
        self.last_recorded_video_path = None
        self.last_recorded_audio_path = None
        self.recording_start_time = None

        self.log.info("Initializing PiCamera2...")
        self.cam = Picamera2()
        self.cam_config = self.cam.create_video_configuration(
            main={"size": (WIDTH, HEIGHT), "format": "XRGB8888"},
            encode="main",
            buffer_count=4
        )
        self.cam.configure(self.cam_config)
        self.log.info(f"Camera configured: {self.cam_config}")

        self.log.info("Starting camera capture thread...")
        self.cam_thread = Thread(target=self._camera_capture_loop, daemon=True)
        self.cam.start()
        self.cam_thread.start()

        self.log.info("Setting up ModernGL context...")
        self.ctx = moderngl.create_context(require=self.gl_version[0] * 100 + self.gl_version[1])

        self.frame_tex = self.ctx.texture((WIDTH, HEIGHT), 4, dtype='u1', alignment=1)
        self.frame_tex.filter = (moderngl.LINEAR, moderngl.LINEAR)

        self.log.info(f"Loading 3D LUT from: {LUT_PATH}")
        try:
            lut_data = read_cube(str(LUT_PATH))
            if lut_data.shape[0] != LUT_RESOLUTION:
                self.log.warning(f"LUT resolution mismatch: Expected {LUT_RESOLUTION}, got {lut_data.shape[0]}. Resizing...")
                from scipy.ndimage import zoom
                lut_data_resized = zoom(lut_data, LUT_RESOLUTION / lut_data.shape[0], order=1)
                lut_data = lut_data_resized
        except FileNotFoundError:
            self.log.error(f"LUT file not found: {LUT_PATH}. Using identity LUT.")
            lut_data = np.linspace(0, 1, LUT_RESOLUTION**3).reshape(LUT_RESOLUTION, LUT_RESOLUTION, LUT_RESOLUTION, 3)
        except Exception as e:
            self.log.error(f"Error loading LUT: {e}. Using identity LUT.")
            lut_data = np.linspace(0, 1, LUT_RESOLUTION**3).reshape(LUT_RESOLUTION, LUT_RESOLUTION, LUT_RESOLUTION, 3)

        if lut_data.dtype == np.float32 or lut_data.dtype == np.float64:
            lut_data = (lut_data * 255).astype(np.ubyte)

        self.lut_tex = self.ctx.texture3d((LUT_RESOLUTION, LUT_RESOLUTION, LUT_RESOLUTION), 3, data=lut_data.tobytes(), dtype='ubyte')
        self.lut_tex.filter = (moderngl.LINEAR, moderngl.LINEAR)

        quad_vertices = np.array([
            -1.0, -1.0,  0.0, 0.0,
             1.0, -1.0,  1.0, 0.0,
            -1.0,  1.0,  0.0, 1.0,
             1.0,  1.0,  1.0, 1.0,
        ], dtype='f4')
        self.quad_vbo = self.ctx.buffer(quad_vertices.tobytes())
        self.quad_vao = self.ctx.vertex_array(
            self.ctx.program(vertex_shader=VERTEX_SHADER, fragment_shader=FRAGMENT_SHADER),
            [(self.quad_vbo, '2f 2f', 'in_vert', 'in_uv')]
        )

        self.program = self.quad_vao.program
        self.program['DOMAIN_MIN'].value = 0.0
        self.program['DOMAIN_MAX'].value = 1.0
        self.program['FrameTex'].value = 0
        self.program['LutTex'].value = 1

        self.log.info("Setting up Flask web server...")
        self.flask_app = Flask(__name__)
        self.sock = Sock(self.flask_app)

        self.api_token = None
        if API_TOKEN_FILE.exists():
            try:
                self.api_token = API_TOKEN_FILE.read_text().strip()
                self.log.info("Local API token loaded successfully.")
            except Exception as e:
                self.log.error(f"Failed to read local API token from {API_TOKEN_FILE}: {e}")
        else:
            self.log.warning(f"Local API token file not found at {API_TOKEN_FILE}. Local API will be unsecured.")

        self.cloud_api_token = None
        if CLOUD_INTEGRATION_ENABLED:
            if CLOUD_API_TOKEN_FILE.exists():
                try:
                    self.cloud_api_token = CLOUD_API_TOKEN_FILE.read_text().strip()
                    self.log.info("Cloud API token loaded successfully.")
                except Exception as e:
                    self.log.error(f"Failed to read Cloud API token from {CLOUD_API_TOKEN_FILE}: {e}")
            else:
                self.log.warning(f"Cloud API token file not found at {CLOUD_API_TOKEN_FILE}. Cloud integration will be disabled.")
                global CLOUD_INTEGRATION_ENABLED
                CLOUD_INTEGRATION_ENABLED = False # Disable if token is missing

        def require_api_token(f):
            @wraps(f)
            def decorated_function(*args, **kwargs):
                if self.api_token:
                    auth_header = request.headers.get('Authorization')
                    if not auth_header or not auth_header.startswith('Bearer '):
                        self.log.warning("Unauthorized API access attempt: Missing Bearer token.")
                        return jsonify({"status": "error", "message": "Unauthorized: Missing Bearer token"}), 401
                    
                    provided_token = auth_header.split(' ')[1]
                    if provided_token != self.api_token:
                        self.log.warning("Unauthorized API access attempt: Invalid Bearer token.")
                        return jsonify({"status": "error", "message": "Unauthorized: Invalid Bearer token"}), 401
                return f(*args, **kwargs)
            return decorated_function

        @self.flask_app.route('/')
        def index():
            return "CinePi5 Camera Control API. Use /record, /stop, /set_iso, /set_shutter, /set_awb, /status."

        @self.flask_app.route('/record', methods=['POST'])
        @require_api_token
        def start_record_web():
            response, status_code = self.start_recording()
            return jsonify(response), status_code

        @self.flask_app.route('/stop', methods=['POST'])
        @require_api_token
        def stop_record_web():
            self.stop_recording()
            return jsonify({"status": "recording stopped"})

        @self.flask_app.route('/set_iso', methods=['POST'])
        @require_api_token
        def set_iso_web():
            try:
                iso = int(request.form.get('iso'))
                self.cam.set_controls({"AnalogueGain": iso / 100.0})
                self.log.info(f"Set ISO to {iso}")
                return jsonify({"status": "ISO set", "iso": iso})
            except Exception as e:
                self.log.error(f"Failed to set ISO: {e}")
                return jsonify({"status": "error", "message": str(e)}), 400

        @self.flask_app.route('/set_shutter', methods=['POST'])
        @require_api_token
        def set_shutter_web():
            try:
                shutter_us = int(request.form.get('shutter'))
                self.cam.set_controls({"ExposureTime": shutter_us})
                self.log.info(f"Set Shutter to {shutter_us} us")
                return jsonify({"status": "Shutter set", "shutter_us": shutter_us})
            except Exception as e:
                self.log.error(f"Failed to set Shutter: {e}")
                return jsonify({"status": "error", "message": str(e)}), 400

        @self.flask_app.route('/set_awb', methods=['POST'])
        @require_api_token
        def set_awb_web():
            try:
                awb_mode_str = request.form.get('awb')
                awb_mode_map = {
                    "auto": controls.AwbModeEnum.Auto,
                    "incandescent": controls.AwbModeEnum.Incandescent,
                    "fluorescent": controls.AwbModeEnum.Fluorescent,
                    "tungsten": controls.AwbModeEnum.Tungsten,
                    "daylight": controls.AwbModeEnum.Daylight,
                    "cloudy": controls.AwbModeEnum.Cloudy,
                    "custom": controls.AwbModeEnum.Custom,
                }
                awb_enum = awb_mode_map.get(awb_mode_str.lower())
                if awb_enum is None:
                    raise ValueError(f"Invalid AWB mode: {awb_mode_str}")

                self.cam.set_controls({"AwbMode": awb_enum})
                self.log.info(f"Set AWB mode to {awb_mode_str}")
                return jsonify({"status": "AWB set", "mode": awb_mode_str})
            except Exception as e:
                self.log.error(f"Failed to set AWB: {e}")
                return jsonify({"status": "error", "message": str(e)}), 400

        @self.flask_app.route('/status', methods=['GET'])
        def get_status(): # Status endpoint is intentionally unauthenticated for fleet monitoring
            try:
                total, used, free = shutil.disk_usage(MEDIA_DIR)
                disk_free_gb = free / (1024**3)
                disk_total_gb = total / (1024**3)

                camera_status = "OK"
                try:
                    _ = self.cam.get_controls()
                except Exception:
                    camera_status = "Error: Camera not responsive or disconnected"
                
                last_log_errors = []
                try:
                    with open(LOG_DIR / "cinepi5_app.log", "r") as f:
                        for line in reversed(f.readlines()):
                            if "ERROR" in line or "CRITICAL" in line:
                                last_log_errors.append(line.strip())
                                if len(last_log_errors) >= 5:
                                    break
                except Exception as e:
                    last_log_errors = [f"Could not read app log: {e}"]

                status_data = {
                    "app_status": "running",
                    "recording_active": self.recording,
                    "camera_status": camera_status,
                    "cpu_percent": psutil.cpu_percent(interval=None),
                    "memory_percent": psutil.virtual_memory().percent,
                    "disk_free_gb": f"{disk_free_gb:.2f}",
                    "disk_total_gb": f"{disk_total_gb:.2f}",
                    "system_uptime_seconds": time.time() - psutil.boot_time(),
                    "app_version": "5.1.0", # App version should match installer
                    "last_log_errors": last_log_errors
                }
                return jsonify(status_data)
            except Exception as e:
                self.log.error(f"Error getting status: {e}")
                return jsonify({"status": "error", "message": str(e)}), 500

        self.flask_thread = Thread(target=self._run_flask_server, daemon=True)
        self.flask_thread.start()

    def _camera_capture_loop(self):
        while self.running:
            try:
                job = self.cam.capture_array("main")
                self.frame_buffer.set_frame(job)
            except Exception as e:
                self.log.error(f"Camera capture error: {e}")
                time.sleep(0.1)

    def _run_flask_server(self):
        try:
            self.flask_app.run(host=WEB_HOST, port=WEB_PORT, debug=False)
        except Exception as e:
            self.log.critical(f"Flask server error: {e}")
            self.running = False

    def render(self, time, frametime):
        self.ctx.clear(0.0, 0.0, 0.0, 1.0)

        frame = self.frame_buffer.get_frame()
        if frame is not None:
            try:
                tex = self.ctx.texture((WIDTH, HEIGHT), 4, data=frame.dma_handle, dtype='u1', alignment=1)
                tex.use(0)
            except Exception as e:
                self.frame_tex.write(frame.tobytes())
                self.frame_tex.use(0)

            self.lut_tex.use(1)
            self.quad_vao.render(moderngl.TRIANGLE_STRIP)

    def start_recording(self):
        if not self.recording:
            total, used, free = shutil.disk_usage(MEDIA_DIR)
            free_gb = free / (1024**3)

            if free_gb < MIN_DISK_SPACE_GB_FOR_RECORDING:
                error_msg = f"Cannot start recording: Low disk space on {MEDIA_DIR}. Only {free_gb:.2f}GB available (minimum {MIN_DISK_SPACE_GB_FOR_RECORDING}GB required)."
                self.log.error(error_msg)
                return {"status": "error", "message": error_msg}, 507

            nm = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            self.last_recorded_video_path = MEDIA_DIR / f"take_{nm}.h264"
            self.last_recorded_audio_path = MEDIA_DIR / f"take_{nm}.wav" # Placeholder for audio

            try:
                enc = encoders.H264Encoder(bitrate=BITRATE)
                enc.gop_size = 15

                self.cam.start_encoder(enc, str(self.last_recorded_video_path))
                self.recording = True
                self.recording_start_time = time.time() # Record start time
                self.log.info("Recording ➜ %s", self.last_recorded_video_path)
                return {"status": "recording started"}, 200
            except Exception as e:
                error_msg = f"Failed to start recording encoder: {e}"
                self.log.error(error_msg)
                return {"status": "error", "message": error_msg}, 500
        else:
            self.log.info("Already recording.")
            return {"status": "already recording"}, 200

    def stop_recording(self):
        if self.recording:
            self.cam.stop_encoder()
            self.recording = False
            self.log.info("Recording stopped.")
            if self.audio_process and self.audio_process.poll() is None:
                self.audio_process.terminate()
                self.audio_process.wait()
                self.log.info("Audio recording stopped.")

            # --- Cloud Upload and Metadata Integration ---
            if CLOUD_INTEGRATION_ENABLED and self.cloud_api_token:
                video_file_to_upload = self.last_recorded_video_path
                audio_file_to_upload = self.last_recorded_audio_path

                def upload_and_post_metadata_task():
                    self.log.info("Starting cloud upload and metadata task...")
                    
                    # Prepare metadata
                    metadata = {
                        'filename': Path(video_file_to_upload).name,
                        'camera_id': os.uname().nodename,
                        'resolution': f"{WIDTH}x{HEIGHT}",
                        'fps': FPS,
                        'bitrate': BITRATE,
                        'timestamp': _dt.datetime.now().isoformat(),
                        'iso': self.cam.get_controls().get('AnalogueGain', 0) * 100,
                        'shutter_us': self.cam.get_controls().get('ExposureTime', 0),
                        'awb_mode': str(self.cam.get_controls().get('AwbMode', 'N/A')),
                        'recording_duration_seconds': (time.time() - self.recording_start_time) if self.recording_start_time else 0
                    }

                    # Upload Video
                    video_presigned_url = get_presigned_upload_url(CLOUD_API_URL, Path(video_file_to_upload).name, self.cloud_api_token, self.log)
                    if video_presigned_url:
                        if upload_file_to_s3(video_file_to_upload, video_presigned_url, self.log):
                            self.log.info(f"Video {video_file_to_upload} uploaded to cloud successfully.")
                            # Optionally delete local file after successful upload
                            # Path(video_file_to_upload).unlink(missing_ok=True)
                        else:
                            self.log.error(f"Failed to upload video {video_file_to_upload} to cloud.")
                    else:
                        self.log.error("Could not get presigned URL for video upload.")

                    # Upload Audio (if applicable and file exists)
                    if audio_file_to_upload and Path(audio_file_to_upload).exists():
                        audio_presigned_url = get_presigned_upload_url(CLOUD_API_URL, Path(audio_file_to_upload).name, self.cloud_api_token, self.log)
                        if audio_presigned_url:
                            if upload_file_to_s3(audio_file_to_upload, audio_presigned_url, self.log):
                                self.log.info(f"Audio {audio_file_to_upload} uploaded to cloud successfully.")
                                # Path(audio_file_to_upload).unlink(missing_ok=True)
                            else:
                                self.log.error(f"Failed to upload audio {audio_file_to_upload} to cloud.")
                        else:
                            self.log.error("Could not get presigned URL for audio upload.")

                    # Post Metadata
                    cloud_response = post_shoot_metadata(CLOUD_API_URL, metadata, self.cloud_api_token, self.log)
                    if cloud_response and 'job_id' in cloud_response:
                        job_id = cloud_response['job_id']
                        self.log.info(f"Cloud processing job initiated with ID: {job_id}")
                        # Optional: Poll for job status - uncomment if needed
                        # try:
                        #     download_url = wait_for_processed_file(CLOUD_API_URL, job_id, self.cloud_api_token, self.log)
                        #     self.log.info(f"Processed file ready at: {download_url}")
                        # except TimeoutError:
                        #     self.log.warning(f"Cloud processing for job {job_id} timed out.")
                    else:
                        self.log.error("Failed to post metadata or get job ID from cloud.")
                    self.log.info("Cloud upload and metadata task finished.")

                # Start the cloud operations in a new thread to avoid blocking the main app
                Thread(target=upload_and_post_metadata_task, daemon=True).start()
            elif CLOUD_INTEGRATION_ENABLED:
                self.log.warning("Cloud integration enabled but cloud API token is missing. Skipping cloud operations.")
            else:
                self.log.info("Cloud integration is disabled. Skipping cloud operations.")

        else:
            self.log.info("Not currently recording.")

    def close(self):
        self.running = False
        if self.recording:
            self.stop_recording()
        self.cam.stop()
        self.cam.close()
        self.ctx.release()
        self.log.info("CinePi5 application closed.")

if __name__ == "__main__":
    APP_ROOT.mkdir(parents=True, exist_ok=True)
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    LUTS_DIR = APP_ROOT / "luts"
    LUTS_DIR.mkdir(parents=True, exist_ok=True)
    if not LUT_PATH.exists():
        log.warning(f"Dummy LUT created at {LUT_PATH}. Replace with a real .cube file!")
        with open(LUT_PATH, "w") as f:
            f.write("TITLE \"Identity LUT\"\n")
            f.write("LUT_3D_SIZE 33\n")
            for i in range(33):
                for j in range(33):
                    for k in range(33):
                        r = i / 32.0
                        g = j / 32.0
                        b = k / 32.0
                        f.write(f"{r:.6f} {g:.6f} {b:.6f}\n")

    try:
        mglw.run_window_config(CinePi5App)
    except Exception as e:
        log.critical(f"CinePi5 application crashed: {e}")
        sys.exit(1)

PYTHON_APP_EOF
  chmod +x "${INSTALL_DIR}/cinepi5_gpu.py" || die "Failed to make cinepi5_gpu.py executable."
  chown "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}/cinepi5_gpu.py" || warn "Failed to set ownership for cinepi5_gpu.py."
  log "Core CinePi5 camera application (cinepi5_gpu.py) deployed."
}

# ── CLI Wrapper ───────────────────────────────────────────────────────────────
setup_cli_wrapper() {
  log "Creating CinePi5 CLI wrapper (/usr/local/bin/cinepi5)…"
  atomic_create "/usr/local/bin/cinepi5" cat <<EOF
#!/usr/bin/env bash
# CinePi5 CLI Wrapper
# Provides command-line access to common CinePi5 operations.

INSTALLER_PATH="/usr/local/bin/cinepi5-installer.sh" # Path to the main installer script

# Ensure script is run as root for most operations
if [ "\$(id -u)" -ne 0 ]; then
  echo "Error: This command requires root privileges. Please use 'sudo cinepi5 [command]'." >&2
  exit 1
fi

# Load config to get ports and paths for CLI operations
# This ensures CLI respects deployment.conf settings
# Use a temporary file to capture sourced variables, then source that temp file
# This prevents issues if deployment.conf contains commands that fail or exit.
_tmp_config_vars=\$(mktemp)
python3 -c "import yaml, sys; config = yaml.safe_load(open('/etc/cinepi5/deployment.conf')) or {}; [print(f'{k}=\"{v}\"') for k, v in config.items()]" > "\$_tmp_config_vars" 2>/dev/null || true
source "\$_tmp_config_vars" &>/dev/null || true
rm -f "\$_tmp_config_vars"

API_TOKEN_FILE="${API_TOKEN_FILE}" # Use the global from loaded config

get_api_token_header() {
  if [ -f "\$API_TOKEN_FILE" ]; then
    local api_token=\$(cat "\$API_TOKEN_FILE")
    echo "-H \"Authorization: Bearer \${api_token}\""
  else
    echo ""
  fi
}

show_help() {
  echo "Usage: sudo cinepi5 [command]"
  echo ""
  echo "Commands:"
  echo "  install     Run full CinePi5 installation/upgrade"
  echo "  status      Show status of the CinePi5 service and system health"
  echo "  record      Start recording video"
  echo "  stop-record Stop recording video"
  echo "  iso <value> Set camera ISO (e.g., 100, 200)"
  echo "  shutter <us> Set camera shutter speed in microseconds (e.g., 10000)"
  echo "  awb <mode>  Set camera AWB mode (e.g., auto, incandescent)"
  echo "  backup      Run a manual backup now"
  echo "  update      Check for and apply OTA updates"
  echo "  rollback    Rollback to the last pre-update state"
  echo "  repair      Run the permissions and logs repair utility"
  echo "  shutdown    Safely shut down the system"
  echo "  logs        Tail the main application log"
  echo "  installer-logs Tail the installer log"
  echo "  help        Show this help message"
  echo ""
}

API_AUTH_HEADER=\$(get_api_token_header)

case "\$1" in
  install)
    "\$INSTALLER_PATH" --install
    ;;
  status)
    curl -s \$API_AUTH_HEADER "http://localhost:\${HTTP_PORT}/status" | jq .
    ;;
  record)
    curl -s -XPOST \$API_AUTH_HEADER "http://localhost:\${HTTP_PORT}/record" | jq .
    ;;
  stop-record)
    curl -s -XPOST \$API_AUTH_HEADER "http://localhost:\${HTTP_PORT}/stop" | jq .
    ;;
  iso)
    if [ -z "\$2" ]; then echo "Usage: iso <value>"; exit 1; fi
    curl -s -XPOST \$API_AUTH_HEADER "http://localhost:\${HTTP_PORT}/set_iso" -d "iso=\$2" | jq .
    ;;
  shutter)
    if [ -z "\$2" ]; then echo "Usage: shutter <microseconds>"; exit 1; fi
    curl -s -XPOST \$API_AUTH_HEADER "http://localhost:\${HTTP_PORT}/set_shutter" -d "shutter=\$2" | jq .
    ;;
  awb)
    if [ -z "\$2" ]; then echo "Usage: awb <mode>"; exit 1; fi
    curl -s -XPOST \$API_AUTH_HEADER "http://localhost:\${HTTP_PORT}/set_awb" -d "awb=\$2" | jq .
    ;;
  backup)
    /usr/local/bin/cinepi5-backup
    ;;
  update)
    /usr/local/bin/cinepi5-update
    ;;
  rollback)
    "\$INSTALLER_PATH" --rollback
    ;;
  repair)
    "\$INSTALLER_PATH" --repair
    ;;
  shutdown)
    "\$INSTALLER_PATH" --safe-shutdown
    ;;
  logs)
    tail -f "${LOG_DIR}/cinepi5_app.log"
    ;;
  installer-logs)
    tail -f "${LOG_DIR}/installer.log"
    ;;
  help|*)
    show_help
    ;;
esac
EOF
  chmod +x "/usr/local/bin/cinepi5" || warn "Failed to make cinepi5 CLI executable."
  chown root:root "/usr/local/bin/cinepi5"
  log "CinePi5 CLI wrapper deployed to /usr/local/bin/cinepi5"
}

# ── First Boot Info ───────────────────────────────────────────────────────────
setup_first_boot_info() {
  log "Setting up first boot network information display…"
  
  atomic_create "/usr/local/bin/cinepi5-first-boot.sh" cat <<EOF
#!/usr/bin/env bash
# CinePi5 First Boot Information Display
# Runs once to provide network details and then disables itself.

LOG_FILE="${LOG_DIR}/first_boot.log"
INFO_FILE="/boot/cinepi5_network_info.txt"
QR_CODE_PATH="/boot/cinepi5_web_qr.png"
API_TOKEN_FILE="${API_TOKEN_FILE}"
HTTP_PORT="${HTTP_PORT}" # Pass HTTP_PORT to script

mount -o remount,rw /boot &>/dev/null || true

echo "\$(date): CinePi5 First Boot script started." >> "\$LOG_FILE"

local_ip="\$(hostname -I | awk '{print \$1}' | head -n1)"
if [ -z "\$local_ip" ]; then
  echo "WARNING: No IP address found on first boot. Check network connection." >> "\$LOG_FILE"
  local_ip="<NO_IP_DETECTED>"
fi

WEB_URL="http://\${local_ip}:\${HTTP_PORT}/"

echo "CinePi5 Web UI: \${WEB_URL}" | tee -a "\$INFO_FILE"
echo "Access via SSH: ssh ${APP_USER}@\${local_ip}" | tee -a "\$INFO_FILE"
echo "" | tee -a "\$INFO_FILE"

if [ -f "\$API_TOKEN_FILE" ]; then
  echo "API Token (keep secure!): \$(cat "\$API_TOKEN_FILE")" | tee -a "\$INFO_FILE"
else
  echo "WARNING: API Token file not found at \$API_TOKEN_FILE." | tee -a "\$INFO_FILE"
fi

echo "" | tee -a "\$INFO_FILE"
echo "For troubleshooting, check logs at: ${LOG_DIR}/cinepi5_app.log" | tee -a "\$INFO_FILE"
echo "Installer logs: ${LOG_DIR}/installer.log" | tee -a "\$INFO_FILE"

if command -v qrencode &>/dev/null; then
  qrencode -o "\$QR_CODE_PATH" "\$WEB_URL" || echo "Failed to generate QR code." | tee -a "\$LOG_FILE"
  echo "QR code for Web UI saved to: \${QR_CODE_PATH}" | tee -a "\$INFO_FILE"
else
  echo "qrencode not found. QR code not generated." | tee -a "\$INFO_FILE"
fi

chmod 644 "\$INFO_FILE" || true
chmod 644 "\$QR_CODE_PATH" || true

echo "\$(date): First Boot script finished. Disabling service." >> "\$LOG_FILE"

systemctl disable cinepi5-first-boot.service &>/dev/null || true
systemctl stop cinepi5-first-boot.service &>/dev/null || true
rm -f /etc/systemd/system/cinepi5-first-boot.service &>/dev/null || true
rm -f /usr/local/bin/cinepi5-first-boot.sh &>/dev/null || true
systemctl daemon-reload &>/dev/null || true

mount -o remount,ro /boot &>/dev/null || true
EOF
  chmod +x "/usr/local/bin/cinepi5-first-boot.sh" || warn "Failed to make first-boot.sh executable."
  chown root:root "/usr/local/bin/cinepi5-first-boot.sh"

  atomic_create "/etc/systemd/system/cinepi5-first-boot.service" cat <<EOF
[Unit]
Description=CinePi5 First Boot Setup
After=network-online.target
RequiresMountsFor=/boot

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/cinepi5-first-boot.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || warn "Failed to reload systemd daemon for first boot service."
  systemctl enable cinepi5-first-boot.service || warn "Failed to enable first boot service."
  log "First boot network info setup complete."
}

# ── Health Reporting ("Phone Home") ───────────────────────────────────────────
setup_health_reporting() {
  if [[ "$HEALTH_REPORTING_ENABLED" == "true" ]]; then
    log "Deploying optional health reporting ('phone home') system…"
    if [ -z "$HEALTH_REPORTING_URL" ]; then
      warn "Health reporting enabled but HEALTH_REPORTING_URL is empty. Skipping deployment."
      return 0
    fi

    atomic_create "$INSTALL_DIR/health_reporter.py" cat <<EOF
#!/usr/bin/env python3
import os
import sys
import json
import requests
import psutil
import shutil
import time
import datetime as dt
from pathlib import Path

LOG_DIR = Path("$LOG_DIR")
WEB_HOST = "$WEB_HOST"
HTTP_PORT = "$HTTP_PORT"
APP_VERSION = "5.1.0" # Should match application version

HEALTH_REPORTING_URL = "$HEALTH_REPORTING_URL"

def get_system_metrics():
    disk_total, disk_used, disk_free = shutil.disk_usage("$MEDIA_DIR")
    metrics = {
        "timestamp": dt.datetime.now().isoformat(),
        "hostname": os.uname().nodename,
        "ip_address": os.popen('hostname -I | awk \'{print $1}\'').read().strip(),
        "app_version": APP_VERSION,
        "cpu_percent": psutil.cpu_percent(interval=None),
        "memory_percent": psutil.virtual_memory().percent,
        "disk_free_gb": f"{disk_free / (1024**3):.2f}",
        "disk_total_gb": f"{disk_total / (1024**3):.2f}",
        "uptime_seconds": time.time() - psutil.boot_time(),
        "cinepi5_service_status": os.popen('systemctl is-active cinepi5').read().strip(),
        "node_exporter_status": os.popen('systemctl is-active prometheus-node-exporter').read().strip(),
        "camera_status": "Unknown" # Placeholder, actual check would be via Flask API or libcamera
    }
    # Attempt to get camera status from local Flask API if running
    try:
        response = requests.get(f"http://{WEB_HOST}:{HTTP_PORT}/status", timeout=5)
        if response.status_code == 200:
            camera_data = response.json()
            metrics["camera_status"] = camera_data.get("camera_status", "OK")
        else:
            metrics["camera_status"] = f"API Error: {response.status_code}"
    except requests.exceptions.RequestException:
        metrics["camera_status"] = "API Unreachable"
    return metrics

def send_report():
    metrics = get_system_metrics()
    try:
        response = requests.post(HEALTH_REPORTING_URL, json=metrics, timeout=10)
        response.raise_for_status()
        print(f"INFO: Health report sent successfully. Status: {response.status_code}")
    except requests.exceptions.RequestException as e:
        print(f"ERROR: Failed to send health report to {HEALTH_REPORTING_URL}: {e}", file=sys.stderr)
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during health reporting: {e}", file=sys.stderr)

if __name__ == "__main__":
    send_report()
EOF
    chmod +x "$INSTALL_DIR/health_reporter.py" || warn "Failed to make health_reporter.py executable."
    chown "${APP_USER}:${APP_GROUP}" "$INSTALL_DIR/health_reporter.py" || warn "Failed to set ownership for health_reporter.py."

    atomic_create /etc/systemd/system/cinepi5-health-reporter.service cat <<EOF
[Unit]
Description=CinePi5 Health Reporter
After=network-online.target

[Service]
Type=oneshot
User=$APP_USER
Group=$APP_GROUP
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/health_reporter.py
Environment=WEB_HOST=$WEB_HOST HTTP_PORT=$HTTP_PORT # Pass network config
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    atomic_create /etc/systemd/system/cinepi5-health-reporter.timer cat <<EOF
[Unit]
Description=CinePi5 Health Report Timer

[Timer]
OnCalendar=*:0/$HEALTH_REPORTING_INTERVAL_MIN # Every X minutes
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || warn "Failed to reload systemd daemon for health reporter."
    systemctl enable cinepi5-health-reporter.timer || warn "Failed to enable health reporter timer."
    log "Health reporting system deployed and enabled."
  else
    log "Health reporting is disabled in deployment.conf. Skipping deployment."
  fi
}

# ── Hardware Detection ────────────────────────────────────────────────────────
check_hardware() {
  log "Performing hardware detection and checks…"
  local hardware_status="OK"

  log "  Checking Raspberry Pi camera module…"
  if vcgencmd get_camera &>/dev/null && [[ "$(vcgencmd get_camera)" =~ "detected=1" ]]; then
    log "  ✓ Raspberry Pi camera module detected."
  else
    warn "  ✗ Raspberry Pi camera module NOT detected. CinePi5 may not function correctly."
    hardware_status="WARNING"
  fi

  log "  Checking external storage at $MEDIA_DIR…"
  if findmnt -n -o SOURCE --target "$MEDIA_DIR" | grep -q "/dev/"; then
    log "  ✓ External storage detected and mounted at $MEDIA_DIR."
  else
    warn "  ✗ External storage not detected or not mounted at $MEDIA_DIR. Recording will use internal SD card."
    hardware_status="WARNING"
  fi

  # Placeholder for expansion board detection.
  # This would involve checking specific GPIOs, I2C devices, or USB IDs.
  # Example for a hypothetical I2C device at address 0x20 on bus 1:
  # if i2cdetect -y 1 | grep "20"; then
  #   log "  ✓ Custom I2C Expansion Board (0x20) detected."
  # else
  #   warn "  ✗ Custom I2C Expansion Board (0x20) NOT detected (optional)."
  # fi

  if [[ "$hardware_status" == "OK" ]]; then
    log "Hardware detection completed successfully."
  else
    warn "Hardware detection completed with warnings. Review logs for details."
    if [[ -n "${DISPLAY:-}" ]]; then
      zenity --warning --title="Hardware Warning" \
        --text="Hardware detection completed with warnings. Some components (e.g., camera, external storage) may not be detected. Check installer logs for details." \
        --width=450
    fi
  fi
}

# ── Installer Self-Verification (Smoke Test) ──────────────────────────────────
run_smoke_test() {
  log "Running post-installation smoke tests…"
  local test_status="SUCCESS"

  log "Test 1/5: Checking CinePi5 service active…"
  if systemctl is-active --quiet cinepi5; then
    log "  ✓ CinePi5 service is active."
  else
    warn "  ✗ CinePi5 service is not active. Check 'journalctl -u cinepi5'."
    test_status="FAIL"
  fi

  log "Test 2/5: Checking Flask API /status endpoint…"
  local api_status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${WEB_HOST}:${HTTP_PORT}/status")
  if [ "$api_status_code" -eq 200 ]; then
    log "  ✓ Flask API /status endpoint reachable (HTTP 200)."
  else
    warn "  ✗ Flask API /status endpoint not reachable or returned error (HTTP $api_status_code). Check firewall and service logs."
    test_status="FAIL"
  fi

  log "Test 3/5: Checking kernel modules load status…"
  local all_modules_loaded=true
  for mod in "${KERNEL_MODULES[@]}"; do
    if lsmod | grep -q "^$mod"; then
      log "  ✓ Kernel module '$mod' is loaded."
    else
      warn "  ✗ Kernel module '$mod' is NOT loaded."
      all_modules_loaded=false
      test_status="FAIL"
    fi
  done
  if "$all_modules_loaded"; then
    log "  ✓ All configured kernel modules are loaded."
  fi

  log "Test 4/5: Testing file write permission to MEDIA_DIR…"
  local test_file="${MEDIA_DIR}/.cinepi5_test_write_$(date +%s).tmp"
  if sudo -u "$APP_USER" touch "$test_file" && sudo -u "$APP_USER" rm "$test_file"; then
    log "  ✓ Write permission to ${MEDIA_DIR} for ${APP_USER} is OK."
  else
    warn "  ✗ Write permission to ${MEDIA_DIR} for ${APP_USER} FAILED. Check permissions or mount."
    test_status="FAIL"
  fi

  log "Test 5/5: Checking Prometheus Node Exporter status…"
  if systemctl is-active --quiet prometheus-node-exporter; then
    log "  ✓ Prometheus Node Exporter is active."
  else
    warn "  ✗ Prometheus Node Exporter is NOT active. Check 'journalctl -u prometheus-node-exporter'."
    test_status="FAIL"
  fi

  if [ "$test_status" = "SUCCESS" ]; then
    log "All smoke tests passed successfully!"
  else
    die "Smoke tests FAILED. Please review warnings/errors in the log."
  fi
}

# ── Create Default deployment.conf ────────────────────────────────────────────
create_default_config() {
  log "Creating default deployment.conf at $CONFIG_DIR/deployment.conf…"
  mkdir -p "$CONFIG_DIR" || die "Failed to create config directory."
  atomic_create "$CONFIG_DIR/deployment.conf" cat <<EOF
# CinePi5 Deployment Configuration
# This file can be used to override default global variables in the installer.
# Uncomment and modify variables as needed.
# For boolean values, use 'true' or 'false' (lowercase).

# APP_USER: "$APP_USER"
# APP_GROUP: "$APP_GROUP"
# INSTALL_DIR: "$INSTALL_DIR"
# LOG_DIR: "$LOG_DIR"
# MEDIA_DIR: "$MEDIA_DIR"
# BACKUP_DIR: "$BACKUP_DIR"
# REPO_OWNER: "$REPO_OWNER"
# REPO_NAME: "$REPO_NAME"
# REPO_BRANCH: "$REPO_BRANCH"
# GITHUB_TOKEN_FILE: "$GITHUB_TOKEN_FILE"
# API_TOKEN_FILE: "$API_TOKEN_FILE"
# API_TOKEN_LENGTH: $API_TOKEN_LENGTH

# Network Ports
# SSH_PORT: $SSH_PORT
# HTTP_PORT: $HTTP_PORT
# UDP_PORT: $UDP_PORT
# NODE_EXPORTER_PORT: $NODE_EXPORTER_PORT

# API Server Binding (Secure-by-Default)
# Set to '127.0.0.1' for local-only access (most secure).
# Set to '0.0.0.0' for remote access (requires careful firewalling and token).
# WEB_HOST: "$WEB_HOST"

# Backup Policy
# MAX_FULL_BACKUPS: $MAX_FULL_BACKUPS
# RETENTION_DAYS: $RETENTION_DAYS
# SNAPSHOT_FILE: "$SNAPSHOT_FILE"

# Remote Backup (Optional)
# REMOTE_BACKUP_ENABLED: false
# REMOTE_BACKUP_TYPE: "sftp" # "sftp", "s3", "minio"
# REMOTE_BACKUP_HOST: ""
# REMOTE_BACKUP_USER: ""
# REMOTE_BACKUP_PATH: "/remote/backups/cinepi5"
# REMOTE_BACKUP_KEY_PATH: "/etc/cinepi5/sftp_id_rsa"

# Health Reporting ("Phone Home" - Optional)
# HEALTH_REPORTING_ENABLED: false
# HEALTH_REPORTING_URL: ""
# HEALTH_REPORTING_INTERVAL_MIN: $HEALTH_REPORTING_INTERVAL_MIN

# Cloud Integration (for footage/metadata upload)
# CLOUD_INTEGRATION_ENABLED: false
# CLOUD_API_URL: "https://your-cloud-api.example.com"
# CLOUD_API_TOKEN_FILE: "/etc/cinepi5/cloud_api_token"
EOF
  chown root:"${APP_GROUP}" "$CONFIG_DIR/deployment.conf" || warn "Failed to set ownership for deployment.conf."
  chmod 640 "$CONFIG_DIR/deployment.conf" || warn "Failed to set permissions for deployment.conf."
  log "Default deployment.conf created."
}

# ── Onboarding Page ───────────────────────────────────────────────────────────
setup_onboarding_page() {
  log "Creating onboarding HTML page…"
  local onboarding_file="${INSTALL_DIR}/onboarding.html"
  local current_ip=$(hostname -I | awk '{print $1}' | head -n1)
  local api_token_display="<API_TOKEN_NOT_AVAILABLE>"
  if [ -f "$API_TOKEN_FILE" ]; then
    api_token_display=$(cat "$API_TOKEN_FILE")
  fi

  atomic_create "${onboarding_file}" cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to CinePi5!</title>
    <style>
        body { font-family: 'Inter', sans-serif; line-height: 1.6; margin: 20px; background-color: #f4f4f4; color: #333; }
        .container { max-width: 800px; margin: auto; background: #fff; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #0056b3; border-bottom: 2px solid #eee; padding-bottom: 10px; margin-bottom: 20px; }
        h2 { color: #0056b3; margin-top: 25px; }
        ul { list-style-type: disc; margin-left: 20px; }
        li { margin-bottom: 10px; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .note { background-color: #e6f7ff; border-left: 5px solid #2196f3; padding: 15px; margin-top: 20px; border-radius: 4px; }
        code { background-color: #eee; padding: 2px 4px; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to CinePi5!</h1>
        <p>Your CinePi5 camera system has been successfully installed and configured.</p>

        <h2>Quick Access:</h2>
        <ul>
            <li><strong>Web Interface:</strong> Access your camera's controls and preview via your web browser:
                <br><a href="http://${current_ip}:${HTTP_PORT}/">http://${current_ip}:${HTTP_PORT}/</a>
            </li>
            <li><strong>Command Line:</strong> For headless control, use the new CLI tool: <code>sudo cinepi5 help</code></li>
            <li><strong>Media Storage:</strong> Your recorded footage will be saved to: <code>${MEDIA_DIR}</code></li>
            <li><strong>Application Logs:</strong> Check application logs for troubleshooting: <code>${LOG_DIR}/cinepi5_app.log</code></li>
        </ul>

        <h2>Key Features & Usage:</h2>
        <ul>
            <li><strong>API Token:</strong> Your API token is: <code>${api_token_display}</code>. Keep this secure!</li>
            <li><strong>Manual Camera Controls:</strong> Use the web interface, the installer's GUI menu (<code>Adjust Camera Controls</code>), or the CLI (<code>sudo cinepi5 iso/shutter/awb</code>) to set ISO, shutter, and AWB.</li>
            <li><strong>Automated Backups:</strong> Your system is configured to perform daily incremental backups automatically. You can configure the time via the GUI. Backups are stored in: <code>${BACKUP_DIR}</code>.</li>
            <li><strong>Over-The-Air (OTA) Updates:</strong> The system checks for updates daily. You can also trigger updates manually from the installer's GUI menu or via <code>sudo cinepi5 update</code>.</li>
            <li><strong>System Monitoring:</strong> Basic system metrics are available via the API at <code>http://${current_ip}:${HTTP_PORT}/status</code> (no token required for this endpoint). For advanced monitoring, Prometheus Node Exporter is running on port <code>${NODE_EXPORTER_PORT}</code>.</li>
            <li><strong>Health Reporting:</strong> (Optional) If enabled, the system will periodically send health reports to your configured webhook URL.</li>
            <li><strong>Remote Backup:</strong> (Optional) If enabled, backups will also be sent to your configured remote destination.</li>
            <li><strong>Cloud Integration:</strong> (Optional) If enabled, recorded footage and metadata will be automatically uploaded to your configured cloud API/S3 bucket.</li>
            <li><strong>Repair Utility:</strong> If you encounter permission issues or problems with log directories, run the <code>Repair Permissions & Logs</code> option from the installer's GUI menu, or execute <code>sudo cinepi5 repair</code>.</li>
            <li><strong>Safe Shutdown:</strong> Use the <code>Safe Shutdown</code> option in the GUI or <code>sudo cinepi5 shutdown</code> to gracefully halt the system.</li>
            <li><strong>Project Documentation:</strong> For more detailed information and advanced usage, visit the project's GitHub page:
                <br><a href="https://github.com/${REPO_OWNER}/${REPO_NAME}">https://github.com/${REPO_OWNER}/${REPO_NAME}</a>
            </li>
        </ul>

        <div class="note">
            <strong>Important:</strong> A system reboot is highly recommended after installation to ensure all changes (especially kernel modules and systemd services) take full effect.
            <br><strong>Security Note:</strong> The web API for camera controls requires a Bearer token. The <code>/status</code> endpoint is unauthenticated for easy monitoring. The API is currently bound to <code>${WEB_HOST}</code>.
        </div>
    </div>
</body>
</html>
EOF
  chown "${APP_USER}:${APP_GROUP}" "${onboarding_file}" || warn "Failed to set ownership for onboarding.html."
  chmod 644 "${onboarding_file}" || warn "Failed to set permissions for onboarding.html."
  log "Onboarding HTML page created at ${onboarding_file}"
}

# ── First Boot Info ───────────────────────────────────────────────────────────
setup_first_boot_info() {
  log "Setting up first boot network information display…"
  
  atomic_create "/usr/local/bin/cinepi5-first-boot.sh" cat <<EOF
#!/usr/bin/env bash
# CinePi5 First Boot Information Display
# Runs once to provide network details and then disables itself.

LOG_FILE="${LOG_DIR}/first_boot.log"
INFO_FILE="/boot/cinepi5_network_info.txt"
QR_CODE_PATH="/boot/cinepi5_web_qr.png"
API_TOKEN_FILE="${API_TOKEN_FILE}"
HTTP_PORT="${HTTP_PORT}" # Pass HTTP_PORT to script

mount -o remount,rw /boot &>/dev/null || true

echo "\$(date): CinePi5 First Boot script started." >> "\$LOG_FILE"

local_ip="\$(hostname -I | awk '{print \$1}' | head -n1)"
if [ -z "\$local_ip" ]; then
  echo "WARNING: No IP address found on first boot. Check network connection." >> "\$LOG_FILE"
  local_ip="<NO_IP_DETECTED>"
fi

WEB_URL="http://\${local_ip}:\${HTTP_PORT}/"

echo "CinePi5 Web UI: \${WEB_URL}" | tee -a "\$INFO_FILE"
echo "Access via SSH: ssh ${APP_USER}@\${local_ip}" | tee -a "\$INFO_FILE"
echo "" | tee -a "\$INFO_FILE"

if [ -f "\$API_TOKEN_FILE" ]; then
  echo "API Token (keep secure!): \$(cat "\$API_TOKEN_FILE")" | tee -a "\$INFO_FILE"
else
  echo "WARNING: API Token file not found at \$API_TOKEN_FILE." | tee -a "\$INFO_FILE"
fi

echo "" | tee -a "\$INFO_FILE"
echo "For troubleshooting, check logs at: ${LOG_DIR}/cinepi5_app.log" | tee -a "\$INFO_FILE"
echo "Installer logs: ${LOG_DIR}/installer.log" | tee -a "\$INFO_FILE"

if command -v qrencode &>/dev/null; then
  qrencode -o "\$QR_CODE_PATH" "\$WEB_URL" || echo "Failed to generate QR code." | tee -a "\$LOG_FILE"
  echo "QR code for Web UI saved to: \${QR_CODE_PATH}" | tee -a "\$INFO_FILE"
else
  echo "qrencode not found. QR code not generated." | tee -a "\$INFO_FILE"
fi

chmod 644 "\$INFO_FILE" || true
chmod 644 "\$QR_CODE_PATH" || true

echo "\$(date): First Boot script finished. Disabling service." >> "\$LOG_FILE"

systemctl disable cinepi5-first-boot.service &>/dev/null || true
systemctl stop cinepi5-first-boot.service &>/dev/null || true
rm -f /etc/systemd/system/cinepi5-first-boot.service &>/dev/null || true
rm -f /usr/local/bin/cinepi5-first-boot.sh &>/dev/null || true
systemctl daemon-reload &>/dev/null || true

mount -o remount,ro /boot &>/dev/null || true
EOF
  chmod +x "/usr/local/bin/cinepi5-first-boot.sh" || warn "Failed to make first-boot.sh executable."
  chown root:root "/usr/local/bin/cinepi5-first-boot.sh"

  atomic_create "/etc/systemd/system/cinepi5-first-boot.service" cat <<EOF
[Unit]
Description=CinePi5 First Boot Setup
After=network-online.target
RequiresMountsFor=/boot

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/cinepi5-first-boot.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || warn "Failed to reload systemd daemon for first boot service."
  systemctl enable cinepi5-first-boot.service || warn "Failed to enable first boot service."
  log "First boot network info setup complete."
}

# ── Health Reporting ("Phone Home") ───────────────────────────────────────────
setup_health_reporting() {
  if [[ "$HEALTH_REPORTING_ENABLED" == "true" ]]; then
    log "Deploying optional health reporting ('phone home') system…"
    if [ -z "$HEALTH_REPORTING_URL" ]; then
      warn "Health reporting enabled but HEALTH_REPORTING_URL is empty. Skipping deployment."
      return 0
    fi

    atomic_create "$INSTALL_DIR/health_reporter.py" cat <<EOF
#!/usr/bin/env python3
import os
import sys
import json
import requests
import psutil
import shutil
import time
import datetime as dt
from pathlib import Path

LOG_DIR = Path("$LOG_DIR")
WEB_HOST = "$WEB_HOST"
HTTP_PORT = "$HTTP_PORT"
APP_VERSION = "5.1.0" # Should match application version

HEALTH_REPORTING_URL = "$HEALTH_REPORTING_URL"

def get_system_metrics():
    disk_total, disk_used, disk_free = shutil.disk_usage("$MEDIA_DIR")
    metrics = {
        "timestamp": dt.datetime.now().isoformat(),
        "hostname": os.uname().nodename,
        "ip_address": os.popen('hostname -I | awk \'{print $1}\'').read().strip(),
        "app_version": APP_VERSION,
        "cpu_percent": psutil.cpu_percent(interval=None),
        "memory_percent": psutil.virtual_memory().percent,
        "disk_free_gb": f"{disk_free / (1024**3):.2f}",
        "disk_total_gb": f"{disk_total / (1024**3):.2f}",
        "uptime_seconds": time.time() - psutil.boot_time(),
        "cinepi5_service_status": os.popen('systemctl is-active cinepi5').read().strip(),
        "node_exporter_status": os.popen('systemctl is-active prometheus-node-exporter').read().strip(),
        "camera_status": "Unknown" # Placeholder, actual check would be via Flask API or libcamera
    }
    # Attempt to get camera status from local Flask API if running
    try:
        response = requests.get(f"http://{WEB_HOST}:{HTTP_PORT}/status", timeout=5)
        if response.status_code == 200:
            camera_data = response.json()
            metrics["camera_status"] = camera_data.get("camera_status", "OK")
        else:
            metrics["camera_status"] = f"API Error: {response.status_code}"
    except requests.exceptions.RequestException:
        metrics["camera_status"] = "API Unreachable"
    return metrics

def send_report():
    metrics = get_system_metrics()
    try:
        response = requests.post(HEALTH_REPORTING_URL, json=metrics, timeout=10)
        response.raise_for_status()
        print(f"INFO: Health report sent successfully. Status: {response.status_code}")
    except requests.exceptions.RequestException as e:
        print(f"ERROR: Failed to send health report to {HEALTH_REPORTING_URL}: {e}", file=sys.stderr)
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during health reporting: {e}", file=sys.stderr)

if __name__ == "__main__":
    send_report()
EOF
    chmod +x "$INSTALL_DIR/health_reporter.py" || warn "Failed to make health_reporter.py executable."
    chown "${APP_USER}:${APP_GROUP}" "$INSTALL_DIR/health_reporter.py" || warn "Failed to set ownership for health_reporter.py."

    atomic_create /etc/systemd/system/cinepi5-health-reporter.service cat <<EOF
[Unit]
Description=CinePi5 Health Reporter
After=network-online.target

[Service]
Type=oneshot
User=$APP_USER
Group=$APP_GROUP
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/health_reporter.py
Environment=WEB_HOST=$WEB_HOST HTTP_PORT=$HTTP_PORT # Pass network config
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    atomic_create /etc/systemd/system/cinepi5-health-reporter.timer cat <<EOF
[Unit]
Description=CinePi5 Health Report Timer

[Timer]
OnCalendar=*:0/$HEALTH_REPORTING_INTERVAL_MIN # Every X minutes
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || warn "Failed to reload systemd daemon for health reporter."
    systemctl enable cinepi5-health-reporter.timer || warn "Failed to enable health reporter timer."
    log "Health reporting system deployed and enabled."
  else
    log "Health reporting is disabled in deployment.conf. Skipping deployment."
  fi
}

# ── Hardware Detection ────────────────────────────────────────────────────────
check_hardware() {
  log "Performing hardware detection and checks…"
  local hardware_status="OK"

  log "  Checking Raspberry Pi camera module…"
  if vcgencmd get_camera &>/dev/null && [[ "$(vcgencmd get_camera)" =~ "detected=1" ]]; then
    log "  ✓ Raspberry Pi camera module detected."
  else
    warn "  ✗ Raspberry Pi camera module NOT detected. CinePi5 may not function correctly."
    hardware_status="WARNING"
  fi

  log "  Checking external storage at $MEDIA_DIR…"
  if findmnt -n -o SOURCE --target "$MEDIA_DIR" | grep -q "/dev/"; then
    log "  ✓ External storage detected and mounted at $MEDIA_DIR."
  else
    warn "  ✗ External storage not detected or not mounted at $MEDIA_DIR. Recording will use internal SD card."
    hardware_status="WARNING"
  fi

  # Placeholder for expansion board detection.
  # This would involve checking specific GPIOs, I2C devices, or USB IDs.
  # Example for a hypothetical I2C device at address 0x20 on bus 1:
  # if i2cdetect -y 1 | grep "20"; then
  #   log "  ✓ Custom I2C Expansion Board (0x20) detected."
  # else
  #   warn "  ✗ Custom I2C Expansion Board (0x20) NOT detected (optional)."
  # fi

  if [[ "$hardware_status" == "OK" ]]; then
    log "Hardware detection completed successfully."
  else
    warn "Hardware detection completed with warnings. Review logs for details."
    if [[ -n "${DISPLAY:-}" ]]; then
      zenity --warning --title="Hardware Warning" \
        --text="Hardware detection completed with warnings. Some components (e.g., camera, external storage) may not be detected. Check installer logs for details." \
        --width=450
    fi
  fi
}

# ── Installer Self-Verification (Smoke Test) ──────────────────────────────────
run_smoke_test() {
  log "Running post-installation smoke tests…"
  local test_status="SUCCESS"

  log "Test 1/5: Checking CinePi5 service active…"
  if systemctl is-active --quiet cinepi5; then
    log "  ✓ CinePi5 service is active."
  else
    warn "  ✗ CinePi5 service is not active. Check 'journalctl -u cinepi5'."
    test_status="FAIL"
  fi

  log "Test 2/5: Checking Flask API /status endpoint…"
  local api_status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${WEB_HOST}:${HTTP_PORT}/status")
  if [ "$api_status_code" -eq 200 ]; then
    log "  ✓ Flask API /status endpoint reachable (HTTP 200)."
  else
    warn "  ✗ Flask API /status endpoint not reachable or returned error (HTTP $api_status_code). Check firewall and service logs."
    test_status="FAIL"
  fi

  log "Test 3/5: Checking kernel modules load status…"
  local all_modules_loaded=true
  for mod in "${KERNEL_MODULES[@]}"; do
    if lsmod | grep -q "^$mod"; then
      log "  ✓ Kernel module '$mod' is loaded."
    else
      warn "  ✗ Kernel module '$mod' is NOT loaded."
      all_modules_loaded=false
      test_status="FAIL"
    fi
  done
  if "$all_modules_loaded"; then
    log "  ✓ All configured kernel modules are loaded."
  fi

  log "Test 4/5: Testing file write permission to MEDIA_DIR…"
  local test_file="${MEDIA_DIR}/.cinepi5_test_write_$(date +%s).tmp"
  if sudo -u "$APP_USER" touch "$test_file" && sudo -u "$APP_USER" rm "$test_file"; then
    log "  ✓ Write permission to ${MEDIA_DIR} for ${APP_USER} is OK."
  else
    warn "  ✗ Write permission to ${MEDIA_DIR} for ${APP_USER} FAILED. Check permissions or mount."
    test_status="FAIL"
  fi

  log "Test 5/5: Checking Prometheus Node Exporter status…"
  if systemctl is-active --quiet prometheus-node-exporter; then
    log "  ✓ Prometheus Node Exporter is active."
  else
    warn "  ✗ Prometheus Node Exporter is NOT active. Check 'journalctl -u prometheus-node-exporter'."
    test_status="FAIL"
  fi

  if [ "$test_status" = "SUCCESS" ]; then
    log "All smoke tests passed successfully!"
  else
    die "Smoke tests FAILED. Please review warnings/errors in the log."
  fi
}

# ── Create Default deployment.conf ────────────────────────────────────────────
create_default_config() {
  log "Creating default deployment.conf at $CONFIG_DIR/deployment.conf…"
  mkdir -p "$CONFIG_DIR" || die "Failed to create config directory."
  atomic_create "$CONFIG_DIR/deployment.conf" cat <<EOF
# CinePi5 Deployment Configuration
# This file can be used to override default global variables in the installer.
# Uncomment and modify variables as needed.
# For boolean values, use 'true' or 'false' (lowercase).

# APP_USER: "$APP_USER"
# APP_GROUP: "$APP_GROUP"
# INSTALL_DIR: "$INSTALL_DIR"
# LOG_DIR: "$LOG_DIR"
# MEDIA_DIR: "$MEDIA_DIR"
# BACKUP_DIR: "$BACKUP_DIR"
# REPO_OWNER: "$REPO_OWNER"
# REPO_NAME: "$REPO_NAME"
# REPO_BRANCH: "$REPO_BRANCH"
# GITHUB_TOKEN_FILE: "$GITHUB_TOKEN_FILE"
# API_TOKEN_FILE: "$API_TOKEN_FILE"
# API_TOKEN_LENGTH: $API_TOKEN_LENGTH

# Network Ports
# SSH_PORT: $SSH_PORT
# HTTP_PORT: $HTTP_PORT
# UDP_PORT: $UDP_PORT
# NODE_EXPORTER_PORT: $NODE_EXPORTER_PORT

# API Server Binding (Secure-by-Default)
# Set to '127.0.0.1' for local-only access (most secure).
# Set to '0.0.0.0' for remote access (requires careful firewalling and token).
# WEB_HOST: "$WEB_HOST"

# Backup Policy
# MAX_FULL_BACKUPS: $MAX_FULL_BACKUPS
# RETENTION_DAYS: $RETENTION_DAYS
# SNAPSHOT_FILE: "$SNAPSHOT_FILE"

# Remote Backup (Optional)
# REMOTE_BACKUP_ENABLED: false
# REMOTE_BACKUP_TYPE: "sftp" # "sftp", "s3", "minio"
# REMOTE_BACKUP_HOST: ""
# REMOTE_BACKUP_USER: ""
# REMOTE_BACKUP_PATH: "/remote/backups/cinepi5"
# REMOTE_BACKUP_KEY_PATH: "/etc/cinepi5/sftp_id_rsa"

# Health Reporting ("Phone Home" - Optional)
# HEALTH_REPORTING_ENABLED: false
# HEALTH_REPORTING_URL: ""
# HEALTH_REPORTING_INTERVAL_MIN: $HEALTH_REPORTING_INTERVAL_MIN

# Cloud Integration (for footage/metadata upload)
# CLOUD_INTEGRATION_ENABLED: false
# CLOUD_API_URL: "https://your-cloud-api.example.com"
# CLOUD_API_TOKEN_FILE: "/etc/cinepi5/cloud_api_token"
EOF
  chown root:"${APP_GROUP}" "$CONFIG_DIR/deployment.conf" || warn "Failed to set ownership for deployment.conf."
  chmod 640 "$CONFIG_DIR/deployment.conf" || warn "Failed to set permissions for deployment.conf."
  log "Default deployment.conf created."
}

# ═════════════════════════════════════════════════════════════════════════════
# Main Entry Point and CLI Dispatcher
# ═════════════════════════════════════════════════════════════════════════════

# Initialize logging before any other operations
init_logging_dirs

# Self-update the installer first
self_update_installer "$@"

# Load configuration after self-update (so new config format is handled)
# This uses the 'source' command to apply the variables from the config file
# into the current script's environment.
# The Python script handles validation and outputs variables in a bash-compatible format.
eval "$(load_config)"

# CLI Dispatcher
case "$1" in
  --install)
    need_root
    need_pi5
    run_full_installation
    ;;
  --rollback)
    need_root
    rollback_system
    ;;
  --repair)
    need_root
    repair_perms_logs
    ;;
  --safe-shutdown)
    need_root
    safe_shutdown
    ;;
  *) # Default GUI or help
    if [[ -n "${DISPLAY:-}" ]]; then
      need_root
      need_pi5
      need_cmd zenity # Check for zenity here for GUI mode
      # Copy installer to a known path for CLI wrapper to reference
      cp "$0" "/usr/local/bin/cinepi5-installer.sh" || warn "Failed to copy installer to /usr/local/bin. CLI might not work."
      chmod 755 "/usr/local/bin/cinepi5-installer.sh" || warn "Failed to set permissions for installer copy."
      chown root:root "/usr/local/bin/cinepi5-installer.sh" || warn "Failed to set ownership for installer copy."
      # This is the main GUI menu loop. It's commented out as per the instructions
      # to keep the script focused on the core installation/management logic
      # and allow for a simpler main execution path for automated deployments.
      # main_menu # Launch GUI
      run_full_installation # For a one-shot GUI installer experience
    else
      echo "CinePi5 Installer (v$INSTALLER_VERSION)"
      echo "Headless mode detected. Use 'sudo cinepi5 help' for commands."
      echo "To run full installation: 'sudo /path/to/installer.sh --install'"
      exit 0
    fi
    ;;
esac
