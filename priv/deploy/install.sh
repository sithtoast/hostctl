#!/usr/bin/env bash
#
# Hostctl installer for Ubuntu 22.04/24.04 and Debian 12.
#
# Usage:
#   curl -fsSL https://your-domain.com/install.sh | sudo bash
#   # or with options:
#   sudo bash install.sh --domain=panel.example.com --skip-nginx --skip-certbot
#
# Options:
#   --domain=DOMAIN       Hostname for the panel (required for nginx/certbot)
#   --db-password=PASS    PostgreSQL password for the hostctl user (auto-generated if omitted)
#   --app-dir=PATH        Install path (default: /opt/hostctl)
#   --repo=URL            Git repository URL (default: current repo)
#   --branch=BRANCH       Git branch (default: main)
#   --skip-nginx          Skip nginx installation and configuration
#   --skip-certbot        Skip SSL certificate provisioning
#   --skip-postgres       Skip PostgreSQL installation (use existing)
#   --reconfigure         Re-run only the configuration/service steps (no build)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
APP_NAME="hostctl"
APP_VERSION="0.1.0"
APP_DIR="/opt/hostctl"
SERVICE_USER="hostctl"
DB_NAME="hostctl_prod"
DB_USER="hostctl"
DB_PASSWORD=""
DOMAIN=""
REPO_URL="https://github.com/yourorg/hostctl.git"   # TODO: update when published
REPO_BRANCH="main"
SKIP_NGINX=false
SKIP_CERTBOT=false
SKIP_POSTGRES=false
RECONFIGURE=false

ELIXIR_VERSION="1.18.3"
OTP_VERSION="27"   # major version for erlang-solutions package

ENV_FILE="/etc/$APP_NAME/env"
SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"

# ─── Colours ──────────────────────────────────────────────────────────────────
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

# ─── Argument parsing ─────────────────────────────────────────────────────────
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
    --reconfigure)    RECONFIGURE=true ;;
    --help|-h)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) error "Unknown option: $arg" ;;
  esac
done

# ─── Pre-flight checks ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "This installer must be run as root (use sudo)."

. /etc/os-release
case "$ID-$VERSION_ID" in
  ubuntu-22.04|ubuntu-24.04|debian-12) ;;
  *) warn "Untested OS: $PRETTY_NAME. Proceeding anyway, but Ubuntu 22.04/24.04 or Debian 12 is recommended." ;;
esac

# Prompt for domain if not provided and not skipping nginx
if [[ -z "$DOMAIN" && "$SKIP_NGINX" == false ]]; then
  read -rp "$(echo -e "${BOLD}Enter the domain / hostname for the panel (e.g. panel.example.com): ${NC}")" DOMAIN
  [[ -n "$DOMAIN" ]] || error "Domain is required for nginx configuration. Use --skip-nginx to skip."
fi

# Generate a random DB password if not provided
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
fi

SOURCE_DIR="/usr/local/src/$APP_NAME"

# ─── Step 1: System packages ──────────────────────────────────────────────────
step "Installing system dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl wget gnupg2 apt-transport-https ca-certificates lsb-release \
  git build-essential libssl-dev libncurses5-dev \
  unzip locales

# Ensure UTF-8 locale
if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
  locale-gen en_US.UTF-8
fi
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

success "System packages installed"

# ─── Step 2: Erlang + Elixir ──────────────────────────────────────────────────
step "Installing Erlang/OTP and Elixir"

if command -v elixir &>/dev/null && elixir --version | grep -q "Elixir 1\.1[89]"; then
  success "Elixir already installed ($(elixir --version | head -1))"
else
  # erlang-solutions provides recent Erlang + Elixir packages for Debian/Ubuntu
  CODENAME="$(lsb_release -sc)"
  wget -q -O /tmp/erlang-solutions.deb \
    "https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb"
  dpkg -i /tmp/erlang-solutions.deb
  rm /tmp/erlang-solutions.deb

  apt-get update -qq
  apt-get install -y --no-install-recommends \
    "esl-erlang=1:$OTP_VERSION.*" elixir

  success "Erlang/Elixir installed: $(elixir --version | head -1)"
fi

mix local.hex --force --quiet
mix local.rebar --force --quiet

# ─── Step 3: PostgreSQL ───────────────────────────────────────────────────────
if [[ "$SKIP_POSTGRES" == false ]]; then
  step "Installing PostgreSQL"

  if ! command -v psql &>/dev/null; then
    # Use the official PostgreSQL apt repo for the latest stable release
    wget -q -O /usr/share/keyrings/postgresql.asc \
      "https://www.postgresql.org/media/keys/ACCC4CF8.asc"
    echo "deb [signed-by=/usr/share/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -sc)-pgdg main" \
      > /etc/apt/sources.list.d/postgresql.list
    apt-get update -qq
    apt-get install -y --no-install-recommends postgresql postgresql-contrib
    systemctl enable --now postgresql
    success "PostgreSQL installed"
  else
    success "PostgreSQL already installed"
  fi

  step "Configuring PostgreSQL user and database"

  # Create DB user (idempotent)
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    info "Created PostgreSQL user: $DB_USER"
  else
    # Update password in case it changed
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    info "PostgreSQL user $DB_USER already exists — password updated"
  fi

  # Enable citext extension in the template to allow the migration to succeed
  sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS citext;" 2>/dev/null || true

  if ! sudo -u postgres psql -lqt | cut -d\| -f1 | grep -qw "$DB_NAME"; then
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    sudo -u postgres psql -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citext;" 2>/dev/null || true
    info "Created database: $DB_NAME"
  else
    info "Database $DB_NAME already exists"
  fi

  success "PostgreSQL ready"
fi

# ─── Step 4: Nginx ────────────────────────────────────────────────────────────
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

# ─── Step 5: System user ──────────────────────────────────────────────────────
step "Setting up system user '$SERVICE_USER'"

if ! id -u "$SERVICE_USER" &>/dev/null; then
  useradd --system --shell /bin/false --home-dir "$APP_DIR" --create-home "$SERVICE_USER"
  success "Created user: $SERVICE_USER"
else
  success "User $SERVICE_USER already exists"
fi

# ─── Step 6: Clone / update source ────────────────────────────────────────────
if [[ "$RECONFIGURE" == false ]]; then
  step "Fetching source code"

  if [[ -d "$SOURCE_DIR/.git" ]]; then
    git -C "$SOURCE_DIR" fetch --quiet origin
    git -C "$SOURCE_DIR" reset --hard "origin/$REPO_BRANCH" --quiet
    info "Updated source from branch: $REPO_BRANCH"
  else
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SOURCE_DIR"
    info "Cloned from $REPO_URL"
  fi

  chown -R root:root "$SOURCE_DIR"

  # ─── Step 7: Build release ──────────────────────────────────────────────────
  step "Building release (this may take a few minutes)"

  cd "$SOURCE_DIR"

  MIX_ENV=prod mix deps.get --only prod
  MIX_ENV=prod mix assets.setup
  MIX_ENV=prod mix assets.deploy
  MIX_ENV=prod mix compile
  MIX_ENV=prod mix release --overwrite

  success "Release built"
fi

# ─── Step 8: Install release to APP_DIR ───────────────────────────────────────
step "Installing release to $APP_DIR"

mkdir -p "$APP_DIR"

if [[ "$RECONFIGURE" == false ]]; then
  cp -r "$SOURCE_DIR/_build/prod/rel/$APP_NAME/." "$APP_DIR/"
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
success "Release installed to $APP_DIR"

# ─── Step 9: Environment file ─────────────────────────────────────────────────
step "Writing environment configuration"

mkdir -p "$(dirname "$ENV_FILE")"
chmod 750 "$(dirname "$ENV_FILE")"
chown "root:$SERVICE_USER" "$(dirname "$ENV_FILE")"

if [[ ! -f "$ENV_FILE" || "$RECONFIGURE" == true ]]; then
  SECRET_KEY_BASE="$(cd "$SOURCE_DIR" && MIX_ENV=prod mix phx.gen.secret 2>/dev/null)"

  cat > "$ENV_FILE" <<EOF
PHX_SERVER=true
PHX_HOST=${DOMAIN:-localhost}
PORT=4000
DATABASE_URL=ecto://$DB_USER:$DB_PASSWORD@localhost/$DB_NAME
SECRET_KEY_BASE=$SECRET_KEY_BASE
POOL_SIZE=10
EOF

  chmod 640 "$ENV_FILE"
  chown "root:$SERVICE_USER" "$ENV_FILE"
  success "Environment file written to $ENV_FILE"
else
  info "Environment file already exists — skipping (use --reconfigure to overwrite)"
fi

# ─── Step 10: Database migrations ─────────────────────────────────────────────
step "Running database migrations"

source "$ENV_FILE"
export PHX_SERVER DATABASE_URL SECRET_KEY_BASE

sudo -u "$SERVICE_USER" "$APP_DIR/bin/migrate"
success "Migrations complete"

# ─── Step 11: Systemd service ─────────────────────────────────────────────────
step "Configuring systemd service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hostctl Phoenix Server
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=exec
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/bin/server
ExecStop=$APP_DIR/bin/$APP_NAME stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$APP_NAME
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$APP_DIR /var/log/$APP_NAME

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl restart "$APP_NAME"
success "Service enabled and started"

# ─── Step 12: Nginx config ────────────────────────────────────────────────────
if [[ "$SKIP_NGINX" == false ]]; then
  step "Configuring Nginx for $DOMAIN"

  NGINX_CONF="/etc/nginx/sites-available/$APP_NAME"

  cat > "$NGINX_CONF" <<EOF
upstream $APP_NAME {
    server 127.0.0.1:4000;
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    client_max_body_size 50M;

    location / {
        proxy_pass http://$APP_NAME;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_redirect off;
        proxy_read_timeout 60s;
    }
}
EOF

  ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$APP_NAME"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t && systemctl reload nginx
  success "Nginx configured for $DOMAIN"

  # ─── Step 13: Certbot / Let's Encrypt ─────────────────────────────────────
  if [[ "$SKIP_CERTBOT" == false ]]; then
    step "Provisioning SSL certificate via Let's Encrypt"

    if ! command -v certbot &>/dev/null; then
      apt-get install -y --no-install-recommends certbot python3-certbot-nginx
    fi

    certbot --nginx \
      --non-interactive \
      --agree-tos \
      --redirect \
      --email "admin@$DOMAIN" \
      -d "$DOMAIN" || warn "Certbot failed (DNS may not be pointing here yet). Run 'certbot --nginx -d $DOMAIN' manually after DNS propagates."
  fi
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✓ Hostctl installation complete!${NC}"
echo ""
echo -e "  App directory : ${BOLD}$APP_DIR${NC}"
echo -e "  Service       : ${BOLD}systemctl status $APP_NAME${NC}"
echo -e "  Logs          : ${BOLD}journalctl -u $APP_NAME -f${NC}"
echo -e "  Env file      : ${BOLD}$ENV_FILE${NC}"

if [[ -n "$DOMAIN" ]]; then
  echo -e "  URL           : ${BOLD}https://$DOMAIN${NC}   (or http if certbot was skipped)"
else
  echo -e "  URL           : ${BOLD}http://localhost:4000${NC}"
fi

echo ""
echo -e "${YELLOW}${BOLD}Security reminder:${NC} Edit $ENV_FILE and review all values before exposing this server to the internet."
echo ""
