#!/usr/bin/env bash
#
# Hostctl installer for Ubuntu 22.04/24.04 and Debian 12.
#
# Usage:
#   curl -fsSL https://your-domain.com/install.sh | sudo bash
#   # or with options:
#   sudo bash install.sh [OPTIONS]
#   sudo bash install.sh --interactive
#   sudo bash install.sh --domain=panel.example.com --skip-nginx --skip-certbot
#
# Run with --help for full usage information.

set -euo pipefail

# --- Pinned dependency versions -----------------------------------------------
POSTGRES_MAJOR="17"
OTP_MAJOR="27"
ELIXIR_VERSION="1.18.3"  # must match OTP_MAJOR above
# PHP versions to install for hosted sites (space-separated, first is default)
PHP_VERSIONS="8.3 8.2 8.1"

# --- Defaults -----------------------------------------------------------------
APP_NAME="hostctl"
APP_VERSION="0.1.0"
APP_DIR="/opt/hostctl"
SERVICE_USER="hostctl"
DB_NAME="hostctl_prod"
DB_USER="hostctl"
DB_PASSWORD=""
MYSQL_ROOT_PASSWORD=""
POSTGRES_ROOT_PASSWORD=""
DOMAIN=""
REPO_URL="https://github.com/yourorg/hostctl.git"   # TODO: update when published
REPO_BRANCH="main"
SKIP_NGINX=false
SKIP_CERTBOT=false
SKIP_POSTGRES=false
SKIP_MYSQL=false
MYSQL_FLAVOR="mysql"  # or 'mariadb'
SKIP_PHP=false
RECONFIGURE=false
CLOUDFLARE_PROXY=false
ASSUME_YES=false
VERBOSE=false
LOG_FILE=""

ENV_FILE="/etc/$APP_NAME/env"
SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
DOWNLOAD_DIR="/tmp/hostctl-install-$$"
SOURCE_DIR="/usr/local/src/$APP_NAME"

# --- Colours ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}==> $*${NC}"; }

cleanup() { rm -rf "$DOWNLOAD_DIR"; }
trap cleanup EXIT

# --- Help ---------------------------------------------------------------------
usage() {
  echo -e ""
  echo -e "${BOLD}Hostctl Installer${NC}"
  echo -e "Supported OS: Ubuntu 22.04/24.04, Debian 12"
  echo -e ""
  echo -e "${BOLD}USAGE${NC}"
  echo -e "  sudo bash install.sh [OPTIONS]"
  echo -e "  curl -fsSL https://your-domain.com/install.sh | sudo bash"
  echo -e ""
  echo -e "${BOLD}OPTIONS${NC}"
  echo -e "  ${CYAN}-i, --interactive${NC}          Prompt for all settings before installing"
  echo -e "  ${CYAN}    --domain=DOMAIN${NC}        Hostname for the panel  ${YELLOW}(required for nginx/certbot)${NC}"
  echo -e "  ${CYAN}    --db-password=PASS${NC}     PostgreSQL password      ${YELLOW}(auto-generated if omitted)${NC}"
  echo -e "  ${CYAN}    --app-dir=PATH${NC}         Install path             ${YELLOW}(default: /opt/hostctl)${NC}"
  echo -e "  ${CYAN}    --repo=URL${NC}             Git repository URL"
  echo -e "  ${CYAN}    --branch=BRANCH${NC}        Git branch               ${YELLOW}(default: main)${NC}"
  echo -e "  ${CYAN}    --db-flavor=FLAVOR${NC}     mysql or mariadb         ${YELLOW}(default: mysql)${NC}"
  echo -e ""
  echo -e "${BOLD}SKIP FLAGS${NC}"
  echo -e "  ${CYAN}    --skip-nginx${NC}           Skip nginx installation and configuration"
  echo -e "  ${CYAN}    --skip-certbot${NC}         Skip SSL certificate provisioning"
  echo -e "  ${CYAN}    --skip-postgres${NC}        Skip PostgreSQL installation (use existing)"
  echo -e "  ${CYAN}    --skip-mysql${NC}           Skip MySQL/MariaDB installation"
  echo -e "  ${CYAN}    --skip-php${NC}             Skip PHP-FPM installation"
  echo -e ""
  echo -e "${BOLD}AUTOMATION FLAGS${NC}"
  echo -e "  ${CYAN}-y, --yes${NC}                  Skip confirmation prompts (assume yes)"
  echo -e "  ${CYAN}-v, --verbose${NC}              Show detailed output during installation"
  echo -e "  ${CYAN}    --log=FILE${NC}             Write all output to FILE in addition to stdout"
  echo -e ""
  echo -e "${BOLD}OTHER FLAGS${NC}"
  echo -e "  ${CYAN}    --cloudflare${NC}           Nginx HTTP-only origin behind Cloudflare proxy"
  echo -e "                             (forces X-Forwarded-Proto: https, skips certbot)"
  echo -e "  ${CYAN}    --reconfigure${NC}          Re-run only config/service steps (no build)"
  echo -e "  ${CYAN}-h, --help${NC}                 Show this help message"
  echo -e ""
  echo -e "${BOLD}EXAMPLES${NC}"
  echo -e "  sudo bash install.sh --interactive"
  echo -e "  sudo bash install.sh --domain=panel.example.com"
  echo -e "  sudo bash install.sh --domain=panel.example.com --skip-nginx --skip-certbot"
  echo -e "  sudo bash install.sh --domain=panel.example.com --cloudflare"
  echo -e "  sudo bash install.sh --domain=panel.example.com --yes --log=/var/log/hostctl-install.log"
  echo -e "  sudo bash install.sh --reconfigure --domain=panel.example.com"
  echo -e ""
}

# --- Interactive wizard -------------------------------------------------------
interactive_setup() {
  echo -e ""
  echo -e "${BOLD}${CYAN}Hostctl Interactive Installer${NC}"
  echo -e "Press ${BOLD}Enter${NC} to accept the value shown in ${BOLD}[brackets]${NC}."
  echo -e ""

  # Domain
  local _default_domain="${DOMAIN:-}"
  read -rp "$(echo -e "  ${BOLD}Panel domain / hostname${NC} (e.g. panel.example.com)${_default_domain:+ [${_default_domain}]}: ")" _in
  [[ -n "$_in" ]] && DOMAIN="$_in"

  # App directory
  read -rp "$(echo -e "  ${BOLD}Install path${NC} [${APP_DIR}]: ")" _in
  [[ -n "$_in" ]] && APP_DIR="$_in"

  # DB password
  local _pw_hint
  if [[ -n "$DB_PASSWORD" ]]; then
    _pw_hint="$DB_PASSWORD"
  else
    _pw_hint="<auto-generate>"
  fi
  read -rp "$(echo -e "  ${BOLD}PostgreSQL password for hostctl user${NC} [${_pw_hint}]: ")" _in
  [[ -n "$_in" ]] && DB_PASSWORD="$_in"

  # DB flavor
  read -rp "$(echo -e "  ${BOLD}MySQL flavor${NC} (mysql/mariadb) [${MYSQL_FLAVOR}]: ")" _in
  [[ -n "$_in" ]] && MYSQL_FLAVOR="$_in"

  # Skip MySQL
  read -rp "$(echo -e "  ${BOLD}Skip MySQL/MariaDB installation?${NC} (already installed) [$([ "$SKIP_MYSQL" == true ] && echo 'yes' || echo 'no')]: ")" _in
  case "${_in,,}" in y|yes) SKIP_MYSQL=true ;; n|no) SKIP_MYSQL=false ;; esac

  # Skip Nginx
  read -rp "$(echo -e "  ${BOLD}Skip Nginx installation?${NC} [$([ "$SKIP_NGINX" == true ] && echo 'yes' || echo 'no')]: ")" _in
  case "${_in,,}" in y|yes) SKIP_NGINX=true ;; n|no) SKIP_NGINX=false ;; esac

  if [[ "$SKIP_NGINX" == false ]]; then
    # Cloudflare proxy
    read -rp "$(echo -e "  ${BOLD}Behind Cloudflare proxy?${NC} (skips certbot) [$([ "$CLOUDFLARE_PROXY" == true ] && echo 'yes' || echo 'no')]: ")" _in
    case "${_in,,}" in y|yes) CLOUDFLARE_PROXY=true ;; n|no) CLOUDFLARE_PROXY=false ;; esac

    if [[ "$CLOUDFLARE_PROXY" == false ]]; then
      # Skip certbot
      read -rp "$(echo -e "  ${BOLD}Skip Certbot / SSL?${NC} [$([ "$SKIP_CERTBOT" == true ] && echo 'yes' || echo 'no')]: ")" _in
      case "${_in,,}" in y|yes) SKIP_CERTBOT=true ;; n|no) SKIP_CERTBOT=false ;; esac
    fi
  fi

  # Skip Postgres
  read -rp "$(echo -e "  ${BOLD}Skip PostgreSQL installation?${NC} (already installed) [$([ "$SKIP_POSTGRES" == true ] && echo 'yes' || echo 'no')]: ")" _in
  case "${_in,,}" in y|yes) SKIP_POSTGRES=true ;; n|no) SKIP_POSTGRES=false ;; esac

  # Skip PHP
  read -rp "$(echo -e "  ${BOLD}Skip PHP-FPM installation?${NC} [$([ "$SKIP_PHP" == true ] && echo 'yes' || echo 'no')]: ")" _in
  case "${_in,,}" in y|yes) SKIP_PHP=true ;; n|no) SKIP_PHP=false ;; esac

  echo -e ""
}

# --- Argument parsing ---------------------------------------------------------
INTERACTIVE=false

for arg in "$@"; do
  case "$arg" in
    --domain=*)       DOMAIN="${arg#*=}" ;;
    --db-password=*)  DB_PASSWORD="${arg#*=}" ;;
    --app-dir=*)      APP_DIR="${arg#*=}" ;;
    --repo=*)         REPO_URL="${arg#*=}" ;;
    --branch=*)       REPO_BRANCH="${arg#*=}" ;;
    --skip-nginx)     SKIP_NGINX=true ;;
    --skip-certbot)   SKIP_CERTBOT=true ;;
    --skip-postgres)  SKIP_POSTGRES=true ;;
    --skip-mysql)     SKIP_MYSQL=true ;;
    --db-flavor=*)    MYSQL_FLAVOR="${arg#*=}" ;;
    --skip-php)       SKIP_PHP=true ;;
    --reconfigure)    RECONFIGURE=true ;;
    --cloudflare)     CLOUDFLARE_PROXY=true ;;
    --interactive|-i) INTERACTIVE=true ;;
    --yes|-y)         ASSUME_YES=true ;;
    --verbose|-v)     VERBOSE=true ;;
    --log=*)          LOG_FILE="${arg#*=}" ;;
    --help|-h)        usage; exit 0 ;;
    *) error "Unknown option: $arg" ;;
  esac
done

[[ "$INTERACTIVE" == true ]] && interactive_setup

# --- Logging ------------------------------------------------------------------
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Logging to $LOG_FILE"
fi

# --- Verbose mode -------------------------------------------------------------
if [[ "$VERBOSE" == true ]]; then
  set -x
fi

# --- Helper: auto-confirm prompts when --yes is set ---------------------------
confirm() {
  local prompt="$1" default="${2:-Y}"
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  local reply
  read -rp "$prompt" reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Cloudflare proxy mode skips certbot for the panel itself (Cloudflare terminates TLS
# for the control panel), but certbot + the dns-cloudflare plugin are still installed
# so that hosted domains can obtain Let's Encrypt certs via DNS-01 challenge.
[[ "$CLOUDFLARE_PROXY" == true ]] && SKIP_CERTBOT=true

# Derive package/service names from chosen database flavor
case "$MYSQL_FLAVOR" in
  mysql)
    DB_FLAVOR_LABEL="MySQL"
    DB_PACKAGES="mysql-server mysql-client"
    DB_SERVICE="mysql"
    DB_PKG_CHECK="mysql-server"
    DB_DEBCONF_PKG="mysql-server"
    ;;
  mariadb)
    DB_FLAVOR_LABEL="MariaDB"
    DB_PACKAGES="mariadb-server mariadb-client"
    DB_SERVICE="mariadb"
    DB_PKG_CHECK="mariadb-server"
    DB_DEBCONF_PKG="mariadb-server"
    ;;
  *) error "Invalid --db-flavor: '$MYSQL_FLAVOR'. Choose 'mysql' or 'mariadb'." ;;
esac

# ==============================================================================
# PHASE 0 - PRE-FLIGHT: verify the system before touching anything
# ==============================================================================

step "Pre-flight checks"

[[ $EUID -eq 0 ]] || error "This installer must be run as root (use sudo)."

[[ -f /etc/os-release ]] || error "Cannot detect OS (/etc/os-release not found)."
. /etc/os-release
OS_ID="$ID"
OS_VERSION="$VERSION_ID"
OS_CODENAME="${VERSION_CODENAME:-}"

case "$OS_ID-$OS_VERSION" in
  ubuntu-22.04) OS_CODENAME="jammy"    ;;
  ubuntu-24.04) OS_CODENAME="noble"    ;;
  debian-12)    OS_CODENAME="bookworm" ;;
  *)
    warn "Untested OS: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    warn "Only Ubuntu 22.04/24.04 and Debian 12 are officially supported."
    confirm "Continue anyway? [y/N] " "N" || exit 1
    ;;
esac
info "Detected OS: ${PRETTY_NAME:-$OS_ID $OS_VERSION} ($OS_CODENAME)"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64) DEB_ARCH="arm64" ;;
  *) error "Unsupported CPU architecture: $ARCH. Only x86_64 and arm64 are supported." ;;
esac
info "Architecture: $ARCH ($DEB_ARCH)"

# Check disk space - need at least 3 GB free for source + build + release
AVAIL_KB="$(df -k / | awk 'NR==2 {print $4}')"
if (( AVAIL_KB < 3145728 )); then
  warn "Less than 3 GB free on / ($(( AVAIL_KB / 1024 ))MB available). The build may fail."
  confirm "Continue anyway? [y/N] " "N" || exit 1
fi
info "Disk space: $(( AVAIL_KB / 1024 ))MB available"

# Check RAM - warn below 1 GB
RAM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
(( RAM_KB >= 1048576 )) || warn "Less than 1 GB RAM available. Build may be slow or fail."
info "RAM: $(( RAM_KB / 1024 ))MB"

# Check git is available or can be installed
if ! command -v git &>/dev/null; then
  info "git not found -- will install it in Phase 1"
  # Verify apt can reach it now, so we fail early rather than mid-install
  apt-get update -qq
  apt-cache show git >/dev/null 2>&1 \
    || error "git is not installed and could not be found in apt. Install git and retry."
else
  info "git: $(git --version)"
fi

if [[ -z "$DOMAIN" && "$SKIP_NGINX" == false ]]; then
  read -rp "$(echo -e "${BOLD}Enter the domain / hostname for the panel (e.g. panel.example.com): ${NC}")" DOMAIN
  [[ -n "$DOMAIN" ]] || error "Domain is required for nginx. Use --skip-nginx to skip."
fi

if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    MYSQL_ROOT_PASSWORD="$(grep '^MYSQL_ROOT_URL=' "$ENV_FILE" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|')" || true
  fi
  if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
    MYSQL_ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
  fi
fi

if [[ -z "$POSTGRES_ROOT_PASSWORD" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    POSTGRES_ROOT_PASSWORD="$(grep '^POSTGRES_ROOT_URL=' "$ENV_FILE" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|')" || true
  fi
  if [[ -z "$POSTGRES_ROOT_PASSWORD" ]]; then
    POSTGRES_ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
  fi
fi

if [[ -z "$DB_PASSWORD" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    # Re-use the password already stored in the env file so the DB and env stay in sync
    DB_PASSWORD="$(grep '^DATABASE_URL=' "$ENV_FILE" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|')"
    [[ -n "$DB_PASSWORD" ]] || error "Could not extract DB password from existing $ENV_FILE. Pass --db-password= explicitly."
    info "Re-using existing DB password from $ENV_FILE"
  else
    DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
  fi
fi

echo ""
echo -e "${BOLD}Installation plan:${NC}"
echo -e "  Erlang/OTP    : $OTP_MAJOR  (rabbitmq/rabbitmq-erlang PPA)"
echo -e "  Elixir        : $ELIXIR_VERSION  (github.com/elixir-lang/elixir)"
echo -e "  PostgreSQL    : $POSTGRES_MAJOR  (postgresql.org apt repo)"
echo -e "  Database      : $DB_FLAVOR_LABEL  ($DB_PACKAGES)"
echo -e "  App directory : $APP_DIR"
echo -e "  System user   : $SERVICE_USER"
echo -e "  Database      : $DB_NAME"
[[ -n "$DOMAIN" ]]             && echo -e "  Domain        : $DOMAIN"
[[ "$SKIP_NGINX" == true ]]       && echo -e "  Nginx         : ${YELLOW}skipped${NC}"
[[ "$CLOUDFLARE_PROXY" == true ]] && echo -e "  Nginx mode    : ${CYAN}Cloudflare proxy (HTTP-only origin, no certbot)${NC}"
[[ "$SKIP_CERTBOT" == true && "$CLOUDFLARE_PROXY" == false ]] && echo -e "  SSL/Certbot   : ${YELLOW}skipped${NC}"
[[ "$SKIP_POSTGRES" == true ]]    && echo -e "  PostgreSQL    : ${YELLOW}skipped (using existing)${NC}"
[[ "$SKIP_MYSQL" == true ]]       && echo -e "  Database      : ${YELLOW}skipped${NC}"
[[ "$SKIP_PHP" == true ]]         && echo -e "  PHP-FPM       : ${YELLOW}skipped${NC}"
echo ""
confirm "$(echo -e "${BOLD}Proceed? [Y/n] ${NC}")" "Y" || { echo "Aborted."; exit 0; }

# ==============================================================================
# PHASE 1 - DOWNLOAD: fetch every package before making any system changes
# ==============================================================================

step "Downloading all prerequisites (before making any system changes)"

export DEBIAN_FRONTEND=noninteractive

# Bootstrap: minimum tools required for adding PPAs and downloading
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl gnupg2 ca-certificates lsb-release wget software-properties-common

mkdir -p "$DOWNLOAD_DIR"

# 1a. Erlang + Elixir: rabbitmq/rabbitmq-erlang PPA ----------------------------
info "Adding rabbitmq/rabbitmq-erlang PPA (may take a minute)..."
add-apt-repository -y ppa:rabbitmq/rabbitmq-erlang \
  || error "Failed to add rabbitmq PPA. Check network connectivity to Launchpad."
apt-get update -q

info "Pre-downloading Erlang (large, this may take several minutes)..."
apt-get install -y --no-install-recommends --download-only erlang \
  || error "Failed to pre-cache erlang packages from the PPA."
success "Erlang cached"

# 1b. Elixir: official GitHub release (OTP-matched, avoids Ubuntu apt mismatch) ---
ELIXIR_ZIP="elixir-otp-${OTP_MAJOR}.zip"
ELIXIR_URL="https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/${ELIXIR_ZIP}"
info "Downloading Elixir ${ELIXIR_VERSION} (OTP ${OTP_MAJOR})..."
curl -fsSL -o "$DOWNLOAD_DIR/elixir.zip" "$ELIXIR_URL" \
  || error "Failed to download Elixir ${ELIXIR_VERSION} from GitHub. Check network connectivity."
success "Elixir ${ELIXIR_VERSION} downloaded"

# 1b. PostgreSQL: signing key ---------------------------------------------------
if [[ "$SKIP_POSTGRES" == false ]] && ! command -v psql &>/dev/null; then
  info "Fetching PostgreSQL $POSTGRES_MAJOR signing key..."
  curl -fsSL -o "$DOWNLOAD_DIR/postgresql.asc" \
    "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
    || error "Failed to download PostgreSQL signing key."
  success "PostgreSQL signing key cached"
fi

# 1c. MySQL: pre-download -------------------------------------------------------
if [[ "$SKIP_MYSQL" == false ]] && ! dpkg -l "$DB_PKG_CHECK" 2>/dev/null | grep -q '^ii'; then
  info "Pre-downloading $DB_FLAVOR_LABEL server..."
  echo "$DB_DEBCONF_PKG $DB_DEBCONF_PKG/root_password password $MYSQL_ROOT_PASSWORD" | debconf-set-selections
  echo "$DB_DEBCONF_PKG $DB_DEBCONF_PKG/root_password_again password $MYSQL_ROOT_PASSWORD" | debconf-set-selections
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends --download-only $DB_PACKAGES >/dev/null
  success "$DB_FLAVOR_LABEL packages cached"
fi

# 1d. Pre-cache remaining apt packages ------------------------------------------
info "Pre-downloading build tools and dependencies..."
apt-get install -y --no-install-recommends \
  --download-only \
  build-essential git libssl-dev unzip locales >/dev/null

if [[ "$SKIP_NGINX" == false ]] && ! command -v nginx &>/dev/null; then
  apt-get install -y --no-install-recommends --download-only nginx >/dev/null
fi

if [[ "$SKIP_PHP" == false ]]; then
  info "Pre-downloading PHP-FPM packages..."
  # ondrej/php PPA provides all PHP versions on Ubuntu/Debian
  add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 \
    || error "Failed to add ondrej/php PPA. Check network connectivity."
  apt-get update -qq
  for _ver in $PHP_VERSIONS; do
    apt-get install -y --no-install-recommends --download-only \
      "php${_ver}-fpm" \
      "php${_ver}-cli" \
      "php${_ver}-common" \
      "php${_ver}-mbstring" \
      "php${_ver}-xml" \
      "php${_ver}-curl" \
      "php${_ver}-pgsql" \
      "php${_ver}-mysql" \
      "php${_ver}-zip" \
      "php${_ver}-gd" \
      "php${_ver}-intl" \
      >/dev/null 2>&1 || warn "Some PHP ${_ver} packages unavailable — continuing"
  done
  success "PHP-FPM packages cached"
fi

success "All prerequisites downloaded. No system changes made yet -- starting installation."

# ==============================================================================
# PHASE 2 - INSTALL: everything is in the apt cache; fast and offline-safe
# ==============================================================================

# 2a. System packages -----------------------------------------------------------
step "Installing system packages"

apt-get install -y --no-install-recommends \
  build-essential git libssl-dev unzip locales

if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
  locale-gen en_US.UTF-8
fi
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
success "System packages installed"

# 2b. Erlang (from PPA cache) + Elixir (from downloaded zip) ------------------
step "Installing Erlang and Elixir"

if command -v erl &>/dev/null; then
  success "Erlang already installed ($(erl -noshell -eval 'io:fwrite("~s~n",[erlang:system_info(otp_release)]),halt().' 2>/dev/null | head -1))"
else
  apt-get install -y erlang
  INSTALLED_OTP="$(erl -noshell \
    -eval 'io:fwrite("~s~n",[erlang:system_info(otp_release)]),halt().' 2>/dev/null)"
  success "Erlang OTP $INSTALLED_OTP installed"
fi

if command -v elixir &>/dev/null; then
  success "Elixir already installed ($(elixir --version 2>/dev/null | head -1))"
else
  info "Installing Elixir ${ELIXIR_VERSION}..."
  unzip -qo "$DOWNLOAD_DIR/elixir.zip" -d /usr/local/elixir
  # Add symlinks so elixir/mix/iex are on PATH system-wide
  for bin in elixir elixirc iex mix; do
    ln -sf "/usr/local/elixir/bin/$bin" "/usr/local/bin/$bin"
  done
  success "Elixir ${ELIXIR_VERSION} installed"
fi

mix local.hex --force --quiet
mix local.rebar --force --quiet
success "Hex and Rebar up to date"

# 2d. PostgreSQL ---------------------------------------------------------------
if [[ "$SKIP_POSTGRES" == false ]]; then
  step "Installing PostgreSQL $POSTGRES_MAJOR"

  if ! command -v psql &>/dev/null; then
    install -m 644 "$DOWNLOAD_DIR/postgresql.asc" /usr/share/keyrings/postgresql.asc
    echo "deb [signed-by=/usr/share/keyrings/postgresql.asc] \
https://apt.postgresql.org/pub/repos/apt ${OS_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/postgresql.list
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      "postgresql-$POSTGRES_MAJOR" postgresql-contrib
    systemctl enable --now postgresql
    success "PostgreSQL $POSTGRES_MAJOR installed"
  else
    success "PostgreSQL already installed ($(psql --version))"
  fi

  step "Configuring PostgreSQL user and database"

  # Set a password for the postgres superuser so the app can connect via Postgrex
  sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$POSTGRES_ROOT_PASSWORD';" >/dev/null 2>&1
  info "PostgreSQL superuser password configured"

  if ! sudo -u postgres psql -tAc \
      "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    info "Created PostgreSQL user: $DB_USER"
  else
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    info "PostgreSQL user $DB_USER already exists -- password updated"
  fi

  if ! sudo -u postgres psql -lqt | cut -d\| -f1 | grep -qw "$DB_NAME"; then
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    sudo -u postgres psql -d "$DB_NAME" \
      -c "CREATE EXTENSION IF NOT EXISTS citext;" >/dev/null 2>&1 || true
    info "Created database: $DB_NAME"
  else
    info "Database $DB_NAME already exists"
  fi

  success "PostgreSQL ready"
fi

# 2e. MySQL/MariaDB ------------------------------------------------------------
if [[ "$SKIP_MYSQL" == false ]]; then
  step "Installing $DB_FLAVOR_LABEL"

  if ! dpkg -l "$DB_PKG_CHECK" 2>/dev/null | grep -q '^ii'; then
    # Pre-seed root password to avoid interactive prompts
    echo "$DB_DEBCONF_PKG $DB_DEBCONF_PKG/root_password password $MYSQL_ROOT_PASSWORD" | debconf-set-selections
    echo "$DB_DEBCONF_PKG $DB_DEBCONF_PKG/root_password_again password $MYSQL_ROOT_PASSWORD" | debconf-set-selections
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $DB_PACKAGES
    systemctl enable --now "$DB_SERVICE"
    success "$DB_FLAVOR_LABEL installed"
  else
    success "$DB_FLAVOR_LABEL already installed"
  fi

  step "Securing $DB_FLAVOR_LABEL"

  # Socket auth first (fresh installs), fall back to password auth (already configured)
  mysqladmin -u root password "$MYSQL_ROOT_PASSWORD" 2>/dev/null \
    || mysqladmin -u root -p"$MYSQL_ROOT_PASSWORD" password "$MYSQL_ROOT_PASSWORD" 2>/dev/null \
    || true

  # Remove anonymous users, test database, and disallow remote root login
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-MYSQL_SECURE
    DELETE FROM mysql.user WHERE User='';
    DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DROP DATABASE IF EXISTS test;
    DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
    FLUSH PRIVILEGES;
MYSQL_SECURE

  success "$DB_FLAVOR_LABEL secured"
fi

# 2f. Nginx --------------------------------------------------------------------
if [[ "$SKIP_NGINX" == false ]]; then
  step "Installing Nginx"

  if ! command -v nginx &>/dev/null; then
    apt-get install -y --no-install-recommends nginx
    systemctl enable nginx
    success "Nginx installed"
  else
    success "Nginx already installed"
  fi
fi

# 2g. Docker -------------------------------------------------------------------
step "Installing Docker"

if ! command -v docker &>/dev/null; then
  # Add Docker's official GPG key and repository
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(lsb_release -si | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$DEB_ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -si | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -qq
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  success "Docker installed and started"
else
  success "Docker already installed"
  systemctl start docker 2>/dev/null || true
fi

# 2h. PHP-FPM ------------------------------------------------------------------
# 2i. Certbot (always installed for hosted-domain SSL) -------------------------
step "Installing Certbot for hosted-domain SSL"

if ! command -v certbot &>/dev/null; then
  apt-get install -y --no-install-recommends certbot
fi

if [[ "$CLOUDFLARE_PROXY" == true ]]; then
  # DNS-01 challenge plugin required when domains are behind Cloudflare proxy
  if ! python3 -c "import certbot_dns_cloudflare" &>/dev/null 2>&1; then
    apt-get install -y --no-install-recommends python3-certbot-dns-cloudflare
  fi
  success "Certbot + dns-cloudflare plugin installed"
else
  success "Certbot installed"
fi

if [[ "$SKIP_PHP" == false ]]; then
  step "Installing PHP-FPM (versions: $PHP_VERSIONS)"

  for _ver in $PHP_VERSIONS; do
    if ! command -v "php${_ver}" &>/dev/null; then
      apt-get install -y --no-install-recommends \
        "php${_ver}-fpm" \
        "php${_ver}-cli" \
        "php${_ver}-common" \
        "php${_ver}-mbstring" \
        "php${_ver}-xml" \
        "php${_ver}-curl" \
        "php${_ver}-pgsql" \
        "php${_ver}-mysql" \
        "php${_ver}-zip" \
        "php${_ver}-gd" \
        "php${_ver}-intl" \
        2>/dev/null || warn "Some PHP ${_ver} packages unavailable — continuing"
      systemctl enable "php${_ver}-fpm" 2>/dev/null || true
      systemctl start "php${_ver}-fpm" 2>/dev/null || true
      success "PHP ${_ver}-FPM installed"
    else
      success "PHP ${_ver} already installed"
    fi
  done
fi

# ==============================================================================
# PHASE 3 - APP: clone, build, install, configure
# ==============================================================================

# 3a. System user --------------------------------------------------------------
step "Setting up system user '$SERVICE_USER'"

if ! id -u "$SERVICE_USER" &>/dev/null; then
  useradd --system --shell /bin/false \
    --home-dir "$APP_DIR" --create-home "$SERVICE_USER"
  success "Created user: $SERVICE_USER"
else
  success "User $SERVICE_USER already exists"
fi

# Add hostctl user to docker group for container management
if command -v docker &>/dev/null && getent group docker &>/dev/null; then
  usermod -aG docker "$SERVICE_USER"
  success "Added $SERVICE_USER to docker group"
fi

# 3b. Clone / update source ----------------------------------------------------
if [[ "$RECONFIGURE" == false ]]; then
  step "Fetching source code ($REPO_BRANCH)"

  command -v git &>/dev/null \
    || error "git is not installed. It should have been installed in Phase 2 -- check the logs above."

  if [[ -d "$SOURCE_DIR/.git" ]]; then
    git -C "$SOURCE_DIR" fetch --quiet origin \
      || error "Failed to fetch from $REPO_URL. Check the URL and your network/SSH access."
    git -C "$SOURCE_DIR" reset --hard "origin/$REPO_BRANCH" --quiet
    info "Updated source from branch: $REPO_BRANCH"
  else
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SOURCE_DIR" \
      || error "Failed to clone $REPO_URL. Check the URL and your network/SSH access."
    info "Cloned from $REPO_URL"
  fi

  chown -R root:root "$SOURCE_DIR"

  # 3c. Build release ----------------------------------------------------------
  step "Building release (this may take a few minutes)"

  cd "$SOURCE_DIR"
  MIX_ENV=prod mix deps.get --only prod
  MIX_ENV=prod mix assets.setup
  MIX_ENV=prod mix compile
  MIX_ENV=prod mix assets.deploy
  MIX_ENV=prod mix release --overwrite

  success "Release built"
fi

# 3d. Install release ----------------------------------------------------------
step "Installing release to $APP_DIR"

mkdir -p "$APP_DIR"

if [[ "$RECONFIGURE" == false ]]; then
  cp -r "$SOURCE_DIR/_build/prod/rel/$APP_NAME/." "$APP_DIR/"
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
success "Release installed"

# 3d-1. Log directory ---------------------------------------------------------
mkdir -p "/var/log/$APP_NAME"
chown "root:$SERVICE_USER" "/var/log/$APP_NAME"
chmod 775 "/var/log/$APP_NAME"
success "Log directory: /var/log/$APP_NAME"

# 3d-1b. Backup directory ------------------------------------------------------
mkdir -p "/var/backups/$APP_NAME"
chown "$SERVICE_USER:$SERVICE_USER" "/var/backups/$APP_NAME"
chmod 750 "/var/backups/$APP_NAME"
success "Backup directory: /var/backups/$APP_NAME"

# 3d-2. Webroot directory -----------------------------------------------------
step "Setting up webroot and Nginx site config directories"

# /var/www — where hosted sites live (e.g. /var/www/example.com/public)
mkdir -p /var/www
chown "root:$SERVICE_USER" /var/www
chmod 775 /var/www
success "Webroot: /var/www"

if [[ "$SKIP_NGINX" == false ]]; then
  # Allow the hostctl service user to write vhost configs without root
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  chown "root:$SERVICE_USER" /etc/nginx/sites-available /etc/nginx/sites-enabled
  chmod 775 /etc/nginx/sites-available /etc/nginx/sites-enabled
  success "Nginx sites dirs writable by $SERVICE_USER"

  # Custom SSL cert storage (Let's Encrypt certs stay under /etc/letsencrypt)
  mkdir -p /etc/ssl/hostctl
  chown "root:$SERVICE_USER" /etc/ssl/hostctl
  chmod 750 /etc/ssl/hostctl
  success "SSL cert dir: /etc/ssl/hostctl"
fi

# 3d-3. Update script sudoers --------------------------------------------------
step "Configuring one-click update permissions"

chmod +x "$APP_DIR/bin/update" 2>/dev/null || true
SUDOERS_FILE="/etc/sudoers.d/hostctl-update"
echo "$SERVICE_USER ALL=(root) NOPASSWD: $APP_DIR/bin/update" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null \
  || { warn "sudoers syntax check failed — removing $SUDOERS_FILE"; rm -f "$SUDOERS_FILE"; }
success "Update script can be triggered from the web UI by admins"

# 3d-4. Nginx reload sudoers ---------------------------------------------------
if [[ "$SKIP_NGINX" == false ]]; then
  NGINX_SUDOERS_FILE="/etc/sudoers.d/hostctl-nginx"
  echo "$SERVICE_USER ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx" > "$NGINX_SUDOERS_FILE"
  chmod 440 "$NGINX_SUDOERS_FILE"
  visudo -cf "$NGINX_SUDOERS_FILE" >/dev/null \
    || { warn "sudoers syntax check failed — removing $NGINX_SUDOERS_FILE"; rm -f "$NGINX_SUDOERS_FILE"; }
  success "$SERVICE_USER can reload Nginx without a password"
fi

# 3d-5. Feature setup sudoers --------------------------------------------------
# Grants the service user passwordless sudo for commands needed by the
# admin Features page (install packages, manage services, write configs).
step "Configuring feature management permissions"
FEATURES_SUDOERS="/etc/sudoers.d/hostctl-features"
cat > "$FEATURES_SUDOERS" <<SUDOERS
$SERVICE_USER ALL=(root) NOPASSWD: /usr/bin/true
$SERVICE_USER ALL=(root) NOPASSWD: /usr/bin/systemd-run *
SUDOERS
chmod 440 "$FEATURES_SUDOERS"
visudo -cf "$FEATURES_SUDOERS" >/dev/null \
  || { warn "sudoers syntax check failed — removing $FEATURES_SUDOERS"; rm -f "$FEATURES_SUDOERS"; }
success "$SERVICE_USER can manage optional features from the web UI"

# 3d-5. Certbot letsencrypt directory (owned by service user, no sudo needed) -
LE_DIR="/var/lib/hostctl/letsencrypt"
mkdir -p "$LE_DIR" "$LE_DIR/work" "$LE_DIR/logs"
chown -R "$SERVICE_USER:$SERVICE_USER" "$LE_DIR"
chmod 750 "$LE_DIR"
success "Certbot data dir: $LE_DIR (owned by $SERVICE_USER, no sudo required)"

# 3e. Environment file ---------------------------------------------------------
step "Writing environment configuration"

mkdir -p "$(dirname "$ENV_FILE")"
chmod 750 "$(dirname "$ENV_FILE")"
chown "root:$SERVICE_USER" "$(dirname "$ENV_FILE")"

if [[ ! -f "$ENV_FILE" || "$RECONFIGURE" == true ]]; then
  SECRET_KEY_BASE="$(cd "$SOURCE_DIR" \
    && MIX_ENV=prod mix phx.gen.secret 2>/dev/null)"
  INITIAL_SETUP_TOKEN="$(openssl rand -hex 32)"

  cat > "$ENV_FILE" <<ENVEOF
PHX_SERVER=true
PHX_HOST=${DOMAIN:-localhost}
PORT=4000
DATABASE_URL=ecto://$DB_USER:$DB_PASSWORD@localhost/$DB_NAME
MYSQL_ROOT_URL=mysql://root:$MYSQL_ROOT_PASSWORD@localhost:3306/mysql
POSTGRES_ROOT_URL=postgres://postgres:$POSTGRES_ROOT_PASSWORD@localhost:5432/postgres
SECRET_KEY_BASE=$SECRET_KEY_BASE
INITIAL_SETUP_TOKEN=$INITIAL_SETUP_TOKEN
POOL_SIZE=10
ENVEOF

  chmod 640 "$ENV_FILE"
  chown "root:$SERVICE_USER" "$ENV_FILE"
  success "Environment file written to $ENV_FILE"
else
  info "Environment file already exists -- skipping (use --reconfigure to overwrite)"
fi

# 3f. Database migrations ------------------------------------------------------
step "Running database migrations"

sudo -u "$SERVICE_USER" env $(grep -v '^#' "$ENV_FILE" | xargs) "$APP_DIR/bin/migrate"
success "Migrations complete"

# 3f-1. Write version file -----------------------------------------------------
VERSION_TAG=$(git -C "$SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null \
  || git -C "$SOURCE_DIR" describe --tags 2>/dev/null \
  || echo "")
if [[ -n "$VERSION_TAG" ]]; then
  echo "$VERSION_TAG" > "/etc/$APP_NAME/version"
  success "Version recorded: $VERSION_TAG"
fi

# 3g. Systemd service ----------------------------------------------------------
step "Configuring systemd service"

cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=Hostctl Phoenix Server
After=network.target postgresql.service ${DB_SERVICE}.service
Requires=postgresql.service

[Service]
Type=exec
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/bin/server
ExecStop=$APP_DIR/bin/$APP_NAME stop
ExecStartPre=+/usr/bin/mkdir -p /run/sudo/ts
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$APP_NAME
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$APP_DIR $SOURCE_DIR /var/log/$APP_NAME /var/www /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/ssl/hostctl /var/lib/hostctl /var/backups/$APP_NAME /tmp /run/sudo /var/cache/apt /var/lib/apt /var/lib/dpkg

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl restart "$APP_NAME" || {
  echo ""
  error "Service failed to start. Logs:\n$(journalctl -u "$APP_NAME" -n 50 --no-pager 2>/dev/null)"
}
success "Service enabled and started"

# 3h. Nginx config -------------------------------------------------------------
if [[ "$SKIP_NGINX" == false ]]; then
  step "Configuring Nginx for $DOMAIN"

  NGINX_CONF="/etc/nginx/sites-available/$APP_NAME"

  # Literal heredoc + sed substitution avoids nginx $variable conflicts
  cat > "$NGINX_CONF" <<'NGINXEOF'
upstream APPNAME {
    server 127.0.0.1:4000;
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name SERVERNAME;

    client_max_body_size 50M;

    location / {
        proxy_pass http://APPNAME;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto XFWDPROTO;
        proxy_set_header Host $host;
        proxy_redirect off;
        proxy_read_timeout 60s;
    }
}
NGINXEOF
  if [[ "$CLOUDFLARE_PROXY" == true ]]; then
    sed -i "s/APPNAME/$APP_NAME/g; s/SERVERNAME/$DOMAIN/g; s/XFWDPROTO/https/g" "$NGINX_CONF"
  else
    sed -i "s/APPNAME/$APP_NAME/g; s/SERVERNAME/$DOMAIN/g" "$NGINX_CONF"
    sed -i 's/XFWDPROTO/$scheme/' "$NGINX_CONF"
  fi

  ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$APP_NAME"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t && systemctl reload nginx
  success "Nginx configured for $DOMAIN"

  # 3i. SSL via Certbot (panel domain only) -------------------------------------
  if [[ "$SKIP_CERTBOT" == false ]]; then
    step "Provisioning SSL certificate for the panel via Let's Encrypt"

    if ! dpkg -l python3-certbot-nginx &>/dev/null; then
      apt-get install -y --no-install-recommends python3-certbot-nginx
    fi

    certbot --nginx \
      --non-interactive \
      --agree-tos \
      --redirect \
      --email "admin@$DOMAIN" \
      -d "$DOMAIN" \
      || warn "Certbot failed -- DNS may not point here yet. Run 'certbot --nginx -d $DOMAIN' manually once DNS propagates."
  fi
fi

# --- Done ---------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}Hostctl installation complete!${NC}"
echo ""
echo -e "  App directory : ${BOLD}$APP_DIR${NC}"
echo -e "  Service       : ${BOLD}systemctl status $APP_NAME${NC}"
echo -e "  Logs          : ${BOLD}journalctl -u $APP_NAME -f${NC}"
echo -e "  Env file      : ${BOLD}$ENV_FILE${NC}"

if [[ -n "$DOMAIN" ]]; then
  BASE_URL="https://$DOMAIN"
else
  BASE_URL="http://localhost:4000"
fi
echo -e "  URL           : ${BOLD}$BASE_URL${NC}"

# Read the setup token from the env file (handles both fresh install and --reconfigure)
SETUP_TOKEN="$(grep '^INITIAL_SETUP_TOKEN=' "$ENV_FILE" | cut -d= -f2)"

if [[ -n "$SETUP_TOKEN" ]]; then
  echo ""
  echo -e "${YELLOW}${BOLD}First-run setup:${NC}"
  echo -e "  Open this link to create your administrator account:"
  echo ""
  echo -e "  ${BOLD}${GREEN}$BASE_URL/setup/$SETUP_TOKEN${NC}"
  echo ""
  echo -e "  ${YELLOW}This link is single-use. Keep it private.${NC}"
fi

echo ""
echo -e "${YELLOW}${BOLD}Security reminder:${NC} Review $ENV_FILE before exposing this server to the internet."
echo ""
