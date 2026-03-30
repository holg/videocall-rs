#!/bin/bash
# Deployment script for videocall-rs
# Configuration is loaded from scripts/deploy-config.toml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deploy-config.toml"

# =============================================================================
# Config parser (simple TOML key = "value" reader)
# =============================================================================
read_config() {
    local key="$1"
    local default="$2"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "$default"
        return
    fi
    local line val
    line=$(grep -E "^${key} *=" "$CONFIG_FILE" | head -1)
    if [[ -z "$line" ]]; then
        echo "$default"
        return
    fi
    # Extract value after '=', strip whitespace and quotes
    val="${line#*=}"
    val="${val## }"
    val="${val%% }"
    val="${val#\"}"
    val="${val%\"}"
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        echo "$default"
    fi
}

# =============================================================================
# Load configuration
# =============================================================================
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE"
    echo "Copy deploy-config.example.toml to deploy-config.toml and edit it."
    exit 1
fi

SSH_HOST=$(read_config "ssh_host" "")
SERVER_NAME=$(read_config "server_name" "")
APP_NAME=$(read_config "app_name" "meeting-api")
REMOTE_BASE=$(read_config "remote_base" "")
SITE_URL=$(read_config "site_url" "")
TARGET_TRIPLE=$(read_config "target_triple" "x86_64-unknown-linux-gnu")
RUST_TOOLCHAIN=$(read_config "rust_toolchain" "stable")
WASM_OPT_VERSION=$(read_config "wasm_opt_version" "version_123")
LISTEN_ADDR=$(read_config "listen_addr" "127.0.0.1:8089")
DATABASE_URL=$(read_config "database_url" "sqlite:./data/meetings.db")
COOKIE_SECURE=$(read_config "cookie_secure" "true")
RUST_LOG_LEVEL=$(read_config "rust_log" "info")
WS_PORT=$(read_config "ws_port" "8080")

if [[ -z "$SSH_HOST" || -z "$REMOTE_BASE" ]]; then
    echo "Error: ssh_host and remote_base must be set in $CONFIG_FILE"
    exit 1
fi

# Allow env var overrides
SSH_HOST="${SSH_HOST_OVERRIDE:-$SSH_HOST}"

# Derived paths
LOCAL_BUILD_DIR="target/$TARGET_TRIPLE/release"
LOCAL_FRONTEND_DIR="dioxus-ui/dist"
REMOTE_BIN_DIR="$REMOTE_BASE"
REMOTE_HTML_DIR="$REMOTE_BASE/html"
REMOTE_DATA_DIR="$REMOTE_BASE/data"
REMOTE_BACKUP_DIR="$REMOTE_BASE/backups"

# Ensure we run from project root
cd "$PROJECT_DIR"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
    build          Build the release binary for Linux + frontend
    build-backend  Build only the backend binary
    build-frontend Build only the Dioxus frontend
    deploy         Backup + Upload + Restart (uses already-built binary)
    full           Build + Backup + Upload + Restart (full deploy)
    upload         Upload built files to server
    setup          First-time setup: create dirs, systemd service, init DB
    init-db        Initialize SQLite database on server (idempotent)
    gen-nginx      Generate nginx config from deploy-config.toml
    install-nginx  Upload and install nginx config on server
    restart        Restart the service on server
    logs           Show service logs (follow)
    status         Show service status
    backup         Create a backup of the current version on the server
    backups        List all available backups
    restore        Restore a backup (interactive selection)

Config: $CONFIG_FILE
Server: $SSH_HOST:$REMOTE_BASE

Examples:
    $0 build                     # Build backend + frontend
    $0 deploy                    # Deploy (backup + upload + restart)
    $0 full                      # Full: build + deploy in one step
    $0 logs                      # Tail logs
EOF
    exit 1
}

# =============================================================================
# Helpers
# =============================================================================
ssh_cmd() {
    ssh "$SSH_HOST" "$@"
}

# =============================================================================
# Commands
# =============================================================================
cmd_build() {
    cmd_build_backend
    cmd_build_frontend
}

cmd_build_backend() {
    echo "=== Building backend for $TARGET_TRIPLE ==="
    ./scripts/cross_build_on_mac.sh "$TARGET_TRIPLE"

    if [[ -f "$LOCAL_BUILD_DIR/$APP_NAME" ]]; then
        echo "✓ Binary built: $LOCAL_BUILD_DIR/$APP_NAME"
        echo "  Size: $(du -h "$LOCAL_BUILD_DIR/$APP_NAME" | cut -f1)"
    else
        echo "✗ Build failed - binary not found"
        exit 1
    fi
}

cmd_build_frontend() {
    echo "=== Building Dioxus frontend ==="
    cd dioxus-ui
    rm -rf dist ../target/wasm-bindgen ../target/wasm-opt

    # Generate tailwind CSS
    if command -v tailwindcss >/dev/null 2>&1; then
        tailwindcss -i ./static/leptos-style.css -o ./static/tailwind.css --minify
    elif command -v npx >/dev/null 2>&1; then
        npx tailwindcss@3 -i ./static/leptos-style.css -o ./static/tailwind.css --minify
    else
        echo "Warning: tailwindcss not found, using existing CSS"
    fi

    # Generate production config.js (trunk copies from dioxus-ui/scripts/)
    cat > ./scripts/config.js <<CONFIGEOF
window.__APP_CONFIG = Object.freeze({
  apiBaseUrl: "$SITE_URL",
  wsUrl: "wss://$SERVER_NAME",
  webTransportHost: "https://$SERVER_NAME:4433",
  oauthEnabled: "false",
  e2eeEnabled: "false",
  webTransportEnabled: "false",
  firefoxEnabled: "false",
  usersAllowedToStream: "",
  serverElectionPeriodMs: 2000,
  audioBitrateKbps: 65,
  videoBitrateKbps: 100,
  screenBitrateKbps: 100,
  oauthProvider: "",
  vadThreshold: 0.02
});
CONFIGEOF

    TRUNK_TOOLS_WASM_OPT="$WASM_OPT_VERSION" rustup run "$RUST_TOOLCHAIN" trunk build --release
    cd "$PROJECT_DIR"

    if [[ -d "$LOCAL_FRONTEND_DIR" ]]; then
        echo "✓ Frontend built: $LOCAL_FRONTEND_DIR"
        echo "  Files: $(find "$LOCAL_FRONTEND_DIR" -type f | wc -l | tr -d ' ')"
    else
        echo "✗ Frontend build failed - dist/ not found"
        exit 1
    fi
}

cmd_backup() {
    echo "=== Creating backup on $SSH_HOST ==="

    ssh_cmd "sudo bash -s" <<REMOTE_EOF
set -e

REMOTE_BASE="$REMOTE_BASE"
APP_NAME="$APP_NAME"
BACKUP_DIR="\$REMOTE_BASE/backups"

mkdir -p "\$BACKUP_DIR"

if [ ! -f "\$REMOTE_BASE/\$APP_NAME" ]; then
    echo "No binary found at \$REMOTE_BASE/\$APP_NAME - nothing to back up"
    exit 0
fi

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="videocall_\${TIMESTAMP}"
STAGING="/tmp/\$BACKUP_NAME"

mkdir -p "\$STAGING"
cp "\$REMOTE_BASE/\$APP_NAME" "\$STAGING/"
[ -f "\$REMOTE_BASE/.env" ] && cp "\$REMOTE_BASE/.env" "\$STAGING/"
[ -d "\$REMOTE_BASE/html" ] && cp -r "\$REMOTE_BASE/html" "\$STAGING/"
[ -d "\$REMOTE_BASE/data" ] && cp -r "\$REMOTE_BASE/data" "\$STAGING/"
echo "Backup created: \$TIMESTAMP" > "\$STAGING/BACKUP_INFO.txt"

cd /tmp
tar czf "\$BACKUP_DIR/\${BACKUP_NAME}.tar.gz" "\$BACKUP_NAME"
rm -rf "\$STAGING"

SIZE=\$(du -h "\$BACKUP_DIR/\${BACKUP_NAME}.tar.gz" | cut -f1)
echo "✓ Backup created: \${BACKUP_NAME}.tar.gz (\$SIZE)"

# Keep last 10 backups
cd "\$BACKUP_DIR"
BACKUP_COUNT=\$(ls -1 videocall_*.tar.gz 2>/dev/null | wc -l)
if [ "\$BACKUP_COUNT" -gt 10 ]; then
    REMOVE_COUNT=\$((BACKUP_COUNT - 10))
    ls -1t videocall_*.tar.gz | tail -n "\$REMOVE_COUNT" | xargs rm -f
    echo "Cleaned up \$REMOVE_COUNT old backup(s), keeping last 10"
fi
REMOTE_EOF
}

cmd_backups() {
    echo "=== Available backups on $SSH_HOST ==="
    echo ""

    ssh_cmd "sudo bash -s" <<REMOTE_EOF
BACKUP_DIR="$REMOTE_BASE/backups"

if [ ! -d "\$BACKUP_DIR" ] || [ -z "\$(ls -A "\$BACKUP_DIR"/videocall_*.tar.gz 2>/dev/null)" ]; then
    echo "No backups found."
    exit 0
fi

printf "%-4s  %-30s  %s\n" "#" "Backup" "Size"
printf "%-4s  %-30s  %s\n" "---" "------------------------------" "--------"

INDEX=1
for f in \$(ls -1t "\$BACKUP_DIR"/videocall_*.tar.gz 2>/dev/null); do
    NAME=\$(basename "\$f" .tar.gz)
    SIZE=\$(du -h "\$f" | cut -f1)
    TS=\$(echo "\$NAME" | sed 's/videocall_//')
    DATE=\$(echo "\$TS" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
    printf "%-4s  %-30s  %s\n" "\$INDEX" "\$DATE" "\$SIZE"
    INDEX=\$((INDEX + 1))
done
REMOTE_EOF
}

cmd_restore() {
    echo "=== Restore backup on $SSH_HOST ==="
    echo ""

    BACKUP_LIST=$(ssh_cmd "sudo ls -1t $REMOTE_BASE/backups/videocall_*.tar.gz 2>/dev/null" || true)

    if [[ -z "$BACKUP_LIST" ]]; then
        echo "No backups found."
        exit 1
    fi

    echo "Available backups:"
    echo ""
    INDEX=1
    while IFS= read -r filepath; do
        NAME=$(basename "$filepath" .tar.gz)
        TS=$(echo "$NAME" | sed 's/videocall_//')
        DATE=$(echo "$TS" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
        SIZE=$(ssh_cmd "sudo du -h '$filepath'" | cut -f1)
        printf "  %2d) %s  (%s)\n" "$INDEX" "$DATE" "$SIZE"
        INDEX=$((INDEX + 1))
    done <<< "$BACKUP_LIST"

    echo ""
    printf "Select backup to restore (1-%d), or 'q' to cancel: " "$((INDEX - 1))"
    read -r SELECTION

    if [[ "$SELECTION" == "q" || "$SELECTION" == "Q" ]]; then
        echo "Cancelled."
        exit 0
    fi

    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [[ "$SELECTION" -lt 1 ]] || [[ "$SELECTION" -ge "$INDEX" ]]; then
        echo "Invalid selection."
        exit 1
    fi

    SELECTED_FILE=$(echo "$BACKUP_LIST" | sed -n "${SELECTION}p")
    SELECTED_NAME=$(basename "$SELECTED_FILE" .tar.gz)

    echo ""
    echo "WARNING: This will:"
    echo "  - Stop the running service"
    echo "  - Replace: $APP_NAME, html/, .env, data/"
    echo "  - Restart the service"
    echo ""
    echo "Selected: $SELECTED_NAME"
    printf "Are you sure? (yes/no): "
    read -r CONFIRM

    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Cancelled."
        exit 0
    fi

    echo ""
    echo "--- Backing up current version before restore ---"
    cmd_backup

    echo ""
    echo "--- Restoring $SELECTED_NAME ---"

    ssh_cmd "sudo bash -s" <<REMOTE_EOF
set -e

REMOTE_BASE="$REMOTE_BASE"
APP_NAME="$APP_NAME"
BACKUP_FILE="$SELECTED_FILE"
BACKUP_NAME="$SELECTED_NAME"

echo "Stopping service..."
systemctl stop "\$APP_NAME" || true

echo "Extracting backup..."
cd /tmp
rm -rf "\$BACKUP_NAME"
tar xzf "\$BACKUP_FILE"

[ -f "/tmp/\$BACKUP_NAME/\$APP_NAME" ] && cp "/tmp/\$BACKUP_NAME/\$APP_NAME" "\$REMOTE_BASE/" && chmod +x "\$REMOTE_BASE/\$APP_NAME" && echo "  Restored: \$APP_NAME"
[ -f "/tmp/\$BACKUP_NAME/.env" ] && cp "/tmp/\$BACKUP_NAME/.env" "\$REMOTE_BASE/" && chmod 600 "\$REMOTE_BASE/.env" && echo "  Restored: .env"
[ -d "/tmp/\$BACKUP_NAME/html" ] && rm -rf "\$REMOTE_BASE/html" && cp -r "/tmp/\$BACKUP_NAME/html" "\$REMOTE_BASE/" && echo "  Restored: html/"
[ -d "/tmp/\$BACKUP_NAME/data" ] && rm -rf "\$REMOTE_BASE/data" && cp -r "/tmp/\$BACKUP_NAME/data" "\$REMOTE_BASE/" && echo "  Restored: data/"

chown -R www-data:www-data "\$REMOTE_BASE"
rm -rf "/tmp/\$BACKUP_NAME"

echo "Starting service..."
systemctl start "\$APP_NAME"
sleep 1
systemctl status "\$APP_NAME" --no-pager || true
REMOTE_EOF

    echo ""
    echo "=== Restore complete ==="
    [[ -n "$SITE_URL" ]] && echo "Site: $SITE_URL"
}

cmd_upload() {
    echo "=== Uploading to $SSH_HOST ==="

    echo "Creating directories..."
    ssh_cmd "sudo mkdir -p $REMOTE_BIN_DIR $REMOTE_HTML_DIR $REMOTE_DATA_DIR $REMOTE_BACKUP_DIR && sudo chown -R \$(whoami) $REMOTE_BASE"

    # Upload binaries
    if [[ -f "$LOCAL_BUILD_DIR/$APP_NAME" ]]; then
        echo "Uploading meeting-api..."
        rsync -avz --progress "$LOCAL_BUILD_DIR/$APP_NAME" "$SSH_HOST:$REMOTE_BIN_DIR/"
    fi
    if [[ -f "$LOCAL_BUILD_DIR/websocket_server" ]]; then
        echo "Uploading websocket_server..."
        rsync -avz --progress "$LOCAL_BUILD_DIR/websocket_server" "$SSH_HOST:$REMOTE_BIN_DIR/"
    fi

    # Upload frontend
    if [[ -d "$LOCAL_FRONTEND_DIR" ]]; then
        echo "Uploading frontend..."
        rsync -avz --delete "$LOCAL_FRONTEND_DIR/" "$SSH_HOST:$REMOTE_HTML_DIR/"
    fi

    # Upload .env if not exists on server
    if ! ssh_cmd "test -f $REMOTE_BIN_DIR/.env"; then
        if [[ -f ".env.production" ]]; then
            echo "Uploading .env.production as .env..."
            scp .env.production "$SSH_HOST:$REMOTE_BIN_DIR/.env"
        else
            echo "Warning: No .env on server — generating with random secrets..."
            JWT_SECRET=$(openssl rand -base64 32)
            ADMIN_SECRET=$(openssl rand -base64 32)
            ssh_cmd "sudo tee $REMOTE_BIN_DIR/.env > /dev/null" <<ENV_EOF
DATABASE_URL=$DATABASE_URL
JWT_SECRET=$JWT_SECRET
ADMIN_SECRET=$ADMIN_SECRET
LISTEN_ADDR=$LISTEN_ADDR
COOKIE_SECURE=$COOKIE_SECURE
RUST_LOG=$RUST_LOG_LEVEL
NATS_URL=nats://127.0.0.1:4222
ACTIX_PORT=$WS_PORT
DATABASE_ENABLED=false
ENV_EOF
            ssh_cmd "sudo chmod 600 $REMOTE_BIN_DIR/.env"
            echo "✓ Generated .env with random JWT_SECRET and ADMIN_SECRET"
            echo ""
            echo "  IMPORTANT: Save the ADMIN_SECRET — you need it to create user invites:"
            echo "  $ADMIN_SECRET"
            echo ""
        fi
    else
        echo "Skipping .env (already exists on server)"
    fi

    # Fix permissions
    ssh_cmd "sudo chown -R www-data:www-data $REMOTE_BASE && sudo chmod +x $REMOTE_BIN_DIR/$APP_NAME"

    echo "✓ Upload complete"
}

cmd_setup() {
    echo "=== First-time setup on $SSH_HOST ==="

    # --- meeting-api service ---
    cat <<EOF | ssh_cmd "sudo tee /etc/systemd/system/$APP_NAME.service > /dev/null"
[Unit]
Description=videocall.rs meeting API server
After=network.target nats.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$REMOTE_BIN_DIR
ExecStart=$REMOTE_BIN_DIR/$APP_NAME
Restart=always
RestartSec=5
EnvironmentFile=$REMOTE_BIN_DIR/.env

[Install]
WantedBy=multi-user.target
EOF

    # --- websocket_server service ---
    cat <<EOF | ssh_cmd "sudo tee /etc/systemd/system/videocall-ws.service > /dev/null"
[Unit]
Description=videocall.rs WebSocket media relay
After=network.target nats.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$REMOTE_BIN_DIR
ExecStart=$REMOTE_BIN_DIR/websocket_server
Restart=always
RestartSec=5
EnvironmentFile=$REMOTE_BIN_DIR/.env

[Install]
WantedBy=multi-user.target
EOF

    ssh_cmd "sudo bash -s" <<REMOTE_EOF
set -e

echo "Creating directories..."
mkdir -p $REMOTE_BIN_DIR $REMOTE_HTML_DIR $REMOTE_DATA_DIR $REMOTE_BACKUP_DIR

# Install NATS if not present
if ! command -v nats-server >/dev/null 2>&1; then
    echo "Installing NATS server..."
    curl -sf https://binaries.nats.dev/nats-io/nats-server/v2@latest | sh
    mv nats-server /usr/local/bin/
    echo "✓ NATS installed"
else
    echo "NATS already installed: \$(nats-server --version)"
fi

# Create NATS systemd service if not exists
if [ ! -f /etc/systemd/system/nats.service ]; then
    cat > /etc/systemd/system/nats.service <<'NATSEOF'
[Unit]
Description=NATS message broker
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nats-server -p 4222
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
NATSEOF
    echo "✓ NATS systemd service created"
fi

echo "Setting permissions..."
chown -R www-data:www-data $REMOTE_BASE
chmod +x $REMOTE_BIN_DIR/$APP_NAME 2>/dev/null || true
chmod +x $REMOTE_BIN_DIR/websocket_server 2>/dev/null || true
chmod 600 $REMOTE_BIN_DIR/.env 2>/dev/null || true

echo "Enabling services..."
systemctl daemon-reload
systemctl enable nats $APP_NAME videocall-ws
systemctl start nats || true

echo "=== Systemd setup complete ==="
REMOTE_EOF

    # Initialize the database
    cmd_init_db

    echo ""
    echo "=== Setup complete ==="
    if ! ssh_cmd "test -f $REMOTE_BIN_DIR/.env"; then
        echo "Run '$0 upload' to generate .env with random secrets"
    else
        echo ".env already exists on server"
    fi
    echo "Run: $0 deploy"
}

cmd_init_db() {
    echo "=== Initializing SQLite database on $SSH_HOST ==="

    scp dbmate/sqlite/migrations/20220807000000_initial_schema.sql "$SSH_HOST:/tmp/videocall_schema.sql"

    ssh_cmd "sudo bash -s" <<REMOTE_EOF
set -e

REMOTE_BASE="$REMOTE_BASE"
DB_FILE="\$REMOTE_BASE/data/meetings.db"

mkdir -p "\$REMOTE_BASE/data"

if [ -f "\$DB_FILE" ]; then
    TABLE_COUNT=\$(sqlite3 "\$DB_FILE" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
    if [ "\$TABLE_COUNT" -gt 0 ]; then
        echo "Database already has \$TABLE_COUNT tables — skipping init"
        echo "Tables: \$(sqlite3 "\$DB_FILE" ".tables")"
        exit 0
    fi
fi

echo "Creating database schema..."
sed -n '/^-- migrate:up\$/,/^-- migrate:down\$/{ /^-- migrate:/d; p; }' /tmp/videocall_schema.sql | sqlite3 "\$DB_FILE"

chown www-data:www-data "\$DB_FILE" "\$REMOTE_BASE/data"
rm -f /tmp/videocall_schema.sql

echo "✓ Database initialized"
sqlite3 "\$DB_FILE" ".tables"
REMOTE_EOF
}

cmd_gen_nginx() {
    if [[ -z "$SERVER_NAME" ]]; then
        echo "Error: server_name must be set in $CONFIG_FILE"
        exit 1
    fi

    local NGINX_FILE="$SCRIPT_DIR/generated-nginx-${SERVER_NAME}.conf"
    local PROXY_PORT="${LISTEN_ADDR##*:}"

    cat > "$NGINX_FILE" <<NGINXEOF
# Generated from deploy-config.toml — do not commit
# Install: $0 install-nginx
# Then: sudo certbot --nginx -d $SERVER_NAME

server {
    listen 80;
    server_name $SERVER_NAME;

    # --- API reverse proxy ---
    location /api/ {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /admin/ {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /auth/ {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /login {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /login/callback {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /logout {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /session {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /profile {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /version {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # --- WebSocket media relay ---
    location /lobby {
        proxy_pass http://127.0.0.1:$WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # --- Static frontend (Dioxus WASM) ---
    root $REMOTE_HTML_DIR;
    index index.html;

    location ~* \.wasm\$ {
        types { application/wasm wasm; }
        gzip_static on;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location ~* -[0-9a-f]+\.(js|css|wasm)\$ {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    # SPA fallback for client-side routing
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/wasm;
    gzip_min_length 256;

    access_log /var/log/nginx/$SERVER_NAME.access.log;
    error_log  /var/log/nginx/$SERVER_NAME.error.log;
}
NGINXEOF

    echo "✓ Generated: $NGINX_FILE"
    echo "  Install with: $0 install-nginx"
}

cmd_install_nginx() {
    if [[ -z "$SERVER_NAME" ]]; then
        echo "Error: server_name must be set in $CONFIG_FILE"
        exit 1
    fi

    local NGINX_FILE="$SCRIPT_DIR/generated-nginx-${SERVER_NAME}.conf"

    if [[ ! -f "$NGINX_FILE" ]]; then
        echo "Nginx config not found. Generating..."
        cmd_gen_nginx
    fi

    echo "=== Installing nginx config on $SSH_HOST ==="
    scp "$NGINX_FILE" "$SSH_HOST:/tmp/$SERVER_NAME"
    ssh_cmd "sudo cp /tmp/$SERVER_NAME /etc/nginx/sites-available/$SERVER_NAME && \
             sudo ln -sf /etc/nginx/sites-available/$SERVER_NAME /etc/nginx/sites-enabled/$SERVER_NAME && \
             sudo nginx -t && \
             sudo systemctl reload nginx"
    echo "✓ Nginx config installed and reloaded"
    echo ""
    echo "For SSL, run on the server:"
    echo "  sudo certbot --nginx -d $SERVER_NAME"
}

cmd_deploy() {
    if [[ ! -f "$LOCAL_BUILD_DIR/$APP_NAME" ]]; then
        echo "✗ No binary found at $LOCAL_BUILD_DIR/$APP_NAME"
        echo "  Run '$0 build' first!"
        exit 1
    fi
    echo "Using binary: $LOCAL_BUILD_DIR/$APP_NAME ($(du -h "$LOCAL_BUILD_DIR/$APP_NAME" | cut -f1))"
    cmd_backup
    cmd_upload
    cmd_init_db
    cmd_restart
    echo ""
    echo "=== Deploy complete ==="
    [[ -n "$SITE_URL" ]] && echo "Site: $SITE_URL"
}

cmd_full() {
    cmd_build
    cmd_deploy
}

cmd_restart() {
    echo "=== Restarting services on $SSH_HOST ==="
    ssh_cmd "sudo systemctl restart nats $APP_NAME videocall-ws && sleep 1 && sudo systemctl status nats $APP_NAME videocall-ws --no-pager"
}

cmd_logs() {
    echo "=== Logs from $SSH_HOST (Ctrl+C to exit) ==="
    ssh_cmd "sudo journalctl -u $APP_NAME -u videocall-ws -f"
}

cmd_status() {
    echo "=== Status on $SSH_HOST ==="
    ssh_cmd "sudo systemctl status nats $APP_NAME videocall-ws --no-pager"
    echo ""
    echo "=== Recent logs ==="
    ssh_cmd "sudo journalctl -u $APP_NAME -u videocall-ws -n 20 --no-pager"
}

# =============================================================================
# Main
# =============================================================================
COMMAND="${1:-}"

case "$COMMAND" in
    build)          cmd_build ;;
    build-backend)  cmd_build_backend ;;
    build-frontend) cmd_build_frontend ;;
    init-db)        cmd_init_db ;;
    gen-nginx)      cmd_gen_nginx ;;
    install-nginx)  cmd_install_nginx ;;
    deploy)         cmd_deploy ;;
    full)           cmd_full ;;
    upload)         cmd_upload ;;
    setup)          cmd_setup ;;
    restart)        cmd_restart ;;
    logs)           cmd_logs ;;
    status)         cmd_status ;;
    backup)         cmd_backup ;;
    backups)        cmd_backups ;;
    restore)        cmd_restore ;;
    *)              usage ;;
esac
