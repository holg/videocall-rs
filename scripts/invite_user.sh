#!/bin/bash
# Create a user invite for videocall-rs
# Usage: ./scripts/invite_user.sh <email> [name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deploy-config.toml"

read_config() {
    local key="$1" default="$2" line val
    line=$(grep -E "^${key} *=" "$CONFIG_FILE" | head -1)
    if [[ -z "$line" ]]; then echo "$default"; return; fi
    val="${line#*=}"; val="${val## }"; val="${val%% }"; val="${val#\"}"; val="${val%\"}"
    if [[ -n "$val" ]]; then echo "$val"; else echo "$default"; fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

EMAIL="${1:-}"
NAME="${2:-$EMAIL}"

if [[ -z "$EMAIL" ]]; then
    echo "Usage: $0 <email> [name]"
    echo ""
    echo "Examples:"
    echo "  $0 alice@example.com Alice"
    echo "  $0 bob@example.com \"Bob Smith\""
    echo ""
    echo "Re-running for an existing email will reset the invite."
    exit 1
fi

SITE_URL=$(read_config "site_url" "")
SSH_HOST=$(read_config "ssh_host" "")
REMOTE_BASE=$(read_config "remote_base" "")

if [[ -z "$SITE_URL" || -z "$SSH_HOST" ]]; then
    echo "Error: site_url and ssh_host must be set in $CONFIG_FILE"
    exit 1
fi

# Get ADMIN_SECRET from server
ADMIN_SECRET=$(ssh "$SSH_HOST" "sudo grep '^ADMIN_SECRET=' $REMOTE_BASE/.env" 2>/dev/null | cut -d= -f2-)

if [[ -z "$ADMIN_SECRET" ]]; then
    echo "Error: Could not read ADMIN_SECRET from $SSH_HOST:$REMOTE_BASE/.env"
    exit 1
fi

# Delete existing user if present (allows re-invite)
ssh "$SSH_HOST" "sudo sqlite3 $REMOTE_BASE/data/meetings.db \"DELETE FROM local_users WHERE email='$EMAIL';\"" 2>/dev/null || true

# Create the invite
RESPONSE=$(curl -s -X POST "$SITE_URL/admin/users" \
    -H "X-Admin-Secret: $ADMIN_SECRET" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\",\"name\":\"$NAME\"}")

SUCCESS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)

if [[ "$SUCCESS" != "True" ]]; then
    echo "Error creating invite:"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    exit 1
fi

TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['invite_token'])")
USER_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['user_id'])")
EXPIRES=$(echo "$RESPONSE" | python3 -c "import sys,json; import datetime; print(datetime.datetime.fromtimestamp(json.load(sys.stdin)['result']['invite_expires_at']).strftime('%Y-%m-%d %H:%M'))")

ACTIVATE_URL="$SITE_URL/activate/$TOKEN"

echo ""
echo "=== Invite created ==="
echo "  Email:   $EMAIL"
echo "  Name:    $NAME"
echo "  User ID: $USER_ID"
echo "  Expires: $EXPIRES"
echo ""
echo "=== Send this link to the user ==="
echo ""
echo "  $ACTIVATE_URL"
echo ""
