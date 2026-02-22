#!/bin/bash
# setup-tenants.sh
#
# Creates the three tenant teams and virtual keys in LiteLLM.
# Run this ONCE after `docker compose up` and the services are healthy.
#
# Teams created:
#   marketing   — gpt-4o-mini, $200/mo hard cap
#   engineering — gpt-4o (+ model override), $2000/mo soft cap
#   support     — gpt-4o-mini, $500/mo hard cap
#
# Usage:
#   bash scripts/setup-tenants.sh
#
# Prerequisites:
#   - .env file with LITELLM_MASTER_KEY set
#   - LiteLLM running on port 8080

set -euo pipefail

# Load master key from .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

MASTER_KEY="${LITELLM_MASTER_KEY:-sk-master-key-change-me}"
BASE_URL="http://localhost:8080"

echo "=== Setting up LLM Control Plane Tenants ==="
echo "Base URL: $BASE_URL"
echo ""

# ─── Helper function ─────────────────────────────────────────────────
create_team() {
    local team_alias="$1"
    local max_budget="$2"
    local budget_duration="$3"
    local models="$4"

    echo "Creating team: $team_alias (budget: \$$max_budget/$budget_duration)"

    response=$(curl -s -X POST "$BASE_URL/team/new" \
        -H "Authorization: Bearer $MASTER_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"team_alias\": \"$team_alias\",
            \"max_budget\": $max_budget,
            \"budget_duration\": \"$budget_duration\",
            \"models\": $models
        }")

    team_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team_id','ERROR'))" 2>/dev/null || echo "ERROR")

    if [ "$team_id" = "ERROR" ] || [ -z "$team_id" ]; then
        echo "  WARNING: Could not create team (may already exist)"
        echo "  Response: $(echo "$response" | head -c 200)"
        # Try to get existing team ID
        team_id=$(curl -s "$BASE_URL/team/list" \
            -H "Authorization: Bearer $MASTER_KEY" | \
            python3 -c "
import sys,json
teams = json.load(sys.stdin)
if isinstance(teams, list):
    for t in teams:
        if t.get('team_alias') == '$team_alias':
            print(t['team_id'])
            break
elif isinstance(teams, dict):
    for t in teams.get('data', teams.get('teams', [])):
        if t.get('team_alias') == '$team_alias':
            print(t['team_id'])
            break
" 2>/dev/null || echo "")
        if [ -n "$team_id" ] && [ "$team_id" != "" ]; then
            echo "  Found existing team: $team_id"
        else
            echo "  ERROR: Could not find or create team $team_alias"
            return 1
        fi
    else
        echo "  Created: $team_id"
    fi

    echo "$team_id"
}

create_key() {
    local team_id="$1"
    local key_alias="$2"
    local models="$3"

    echo "  Creating key: $key_alias"

    response=$(curl -s -X POST "$BASE_URL/key/generate" \
        -H "Authorization: Bearer $MASTER_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"team_id\": \"$team_id\",
            \"key_alias\": \"$key_alias\",
            \"models\": $models
        }")

    key=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key','ERROR'))" 2>/dev/null || echo "ERROR")

    if [ "$key" = "ERROR" ] || [ -z "$key" ]; then
        echo "  WARNING: Could not create key"
        echo "  Response: $(echo "$response" | head -c 200)"
        return 1
    fi

    echo "  Key: $key"
    echo "$key"
}

# ─── Create Teams ────────────────────────────────────────────────────

echo ""
echo "─── Marketing ───────────────────────────────────────"
MARKETING_TEAM_ID=$(create_team "marketing" 200 "30d" '["gpt-4o-mini"]')
echo ""

echo "─── Engineering ─────────────────────────────────────"
ENGINEERING_TEAM_ID=$(create_team "engineering" 2000 "30d" '["gpt-4o", "gpt-4o-mini"]')
echo ""

echo "─── Support ─────────────────────────────────────────"
SUPPORT_TEAM_ID=$(create_team "support" 500 "30d" '["gpt-4o-mini"]')
echo ""

# ─── Create Virtual Keys ─────────────────────────────────────────────

echo "─── Creating Virtual Keys ───────────────────────────"

# Extract just the team IDs (last line of each create_team output)
MKT_ID=$(echo "$MARKETING_TEAM_ID" | tail -1)
ENG_ID=$(echo "$ENGINEERING_TEAM_ID" | tail -1)
SUP_ID=$(echo "$SUPPORT_TEAM_ID" | tail -1)

echo ""
echo "Marketing team ID: $MKT_ID"
MKT_KEY=$(create_key "$MKT_ID" "sk-marketing" '["gpt-4o-mini"]')
MKT_KEY_VAL=$(echo "$MKT_KEY" | tail -1 | grep -o 'sk-.*' || echo "")

echo ""
echo "Engineering team ID: $ENG_ID"
ENG_KEY=$(create_key "$ENG_ID" "sk-engineering" '["gpt-4o", "gpt-4o-mini"]')
ENG_KEY_VAL=$(echo "$ENG_KEY" | tail -1 | grep -o 'sk-.*' || echo "")

echo ""
echo "Support team ID: $SUP_ID"
SUP_KEY=$(create_key "$SUP_ID" "sk-support" '["gpt-4o-mini"]')
SUP_KEY_VAL=$(echo "$SUP_KEY" | tail -1 | grep -o 'sk-.*' || echo "")

# ─── Save keys to .env.tenants ────────────────────────────────────────

echo ""
echo "─── Saving keys to .env.tenants ─────────────────────"

cat > .env.tenants << EOF
# Auto-generated tenant keys — do not commit this file
# Generated by: scripts/setup-tenants.sh
#
# Use these keys to test tenant-specific behavior:
#   curl -H "Authorization: Bearer \$MARKETING_KEY" ...

MARKETING_KEY=$MKT_KEY_VAL
ENGINEERING_KEY=$ENG_KEY_VAL
SUPPORT_KEY=$SUP_KEY_VAL
EOF

echo "Keys saved to .env.tenants"
echo ""
echo "=== Done ==="
echo ""
echo "Test with:"
echo "  source .env.tenants"
echo "  curl http://localhost:8080/v1/chat/completions \\"
echo "    -H \"Authorization: Bearer \$MARKETING_KEY\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
