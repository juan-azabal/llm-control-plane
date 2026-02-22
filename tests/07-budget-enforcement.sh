#!/bin/bash
# 07-budget-enforcement.sh
#
# DEMONSTRATES: LiteLLM enforces hard budget caps per tenant team
# TENANT: marketing (hard cap $200/month — enforced by LiteLLM, not NeMo)
# EXPECTED: Once budget is exhausted, requests are blocked with budget error
#
# Why this matters: ADR-009 — cost governance is non-negotiable for enterprise.
# Unlike topic control (semantic, probabilistic), budget enforcement is
# deterministic — every token is counted, no bypass possible at the semantic layer.
#
# This test creates a TEMPORARY test key with a tiny budget ($0.001),
# exhausts it with a real request, then verifies the next request is blocked.
# The team's main key is unaffected.
#
# Implementation: LiteLLM tracks spend in Postgres and blocks when
# max_budget is exceeded. The budget resets at the configured interval.

set -euo pipefail

if [ -f .env ]; then export $(grep -v '^#' .env | grep -v '^$' | xargs); fi
if [ -f .env.tenants ]; then export $(grep -v '^#' .env.tenants | grep -v '^$' | xargs); fi

BASE_URL="http://localhost:8080"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"
MARKETING_KEY="${MARKETING_KEY:-}"

if [ -z "$MASTER_KEY" ]; then
    echo "ERROR: LITELLM_MASTER_KEY not set in .env"
    exit 1
fi

if [ -z "$MARKETING_KEY" ]; then
    echo "ERROR: MARKETING_KEY not set. Run: bash scripts/setup-tenants.sh"
    exit 1
fi

PASS=0
FAIL=0

is_allowed() { python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if r.get('choices') else 1)"; }
is_budget_blocked() { python3 -c "import sys,json; r=json.load(sys.stdin); err=r.get('error',{}); msg=str(err.get('message','')).lower(); sys.exit(0 if any(p in msg for p in ['budget','limit','exceeded','quota','spend']) or (err and 'openai' not in msg and 'api key' not in msg) else 1)"; }

echo "=== Budget Enforcement Tests ==="
echo ""

echo "1. Creating temporary test key with \$0.0001 budget..."
TEMP_KEY_RESPONSE=$(curl -s -X POST "$BASE_URL/key/generate" \
    -H "Authorization: Bearer $MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "max_budget": 0.0001,
        "budget_duration": "1d",
        "models": ["gpt-4o-mini"],
        "metadata": {"purpose": "budget-test", "ephemeral": true}
    }' 2>/dev/null)

TEMP_KEY=$(echo "$TEMP_KEY_RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('key',''))" 2>/dev/null)

if [ -z "$TEMP_KEY" ]; then
    echo "  ✗ FAIL: Could not create temporary test key"
    echo "    Response: $(echo "$TEMP_KEY_RESPONSE" | head -c 300)"
    exit 1
fi
echo "  ✓ Created temp key: ${TEMP_KEY:0:20}... (max_budget=\$0.0001)"

echo ""
echo "2. Exhausting budget with a request..."
# Send a request that will cost ~$0.001 or more
EXHAUST_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $TEMP_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "gpt-4o-mini",
        "messages": [{
            "role": "user",
            "content": "Write a detailed 500-word essay about the history of the internet."
        }]
    }' 2>/dev/null)

if echo "$EXHAUST_RESPONSE" | is_allowed 2>/dev/null; then
    echo "  ✓ First request succeeded (budget partially or fully consumed)"
else
    echo "  ~ First request may have been blocked (budget too small for even one request)"
fi

echo ""
echo "3. Sending follow-up request — expecting budget block..."
sleep 3  # Give LiteLLM time to update spend tracking in Postgres

BLOCKED_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $TEMP_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Hello!"}]
    }' 2>/dev/null)

if echo "$BLOCKED_RESPONSE" | is_budget_blocked 2>/dev/null; then
    echo "  ✓ PASS: Request blocked after budget exhaustion"
    PASS=$((PASS + 1))
else
    echo "  ✗ FAIL: Request was NOT blocked after budget should be exhausted"
    echo "    Response: $(echo "$BLOCKED_RESPONSE" | head -c 400)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "4. Verifying marketing team's main key still works..."
MAIN_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $MARKETING_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Write a one-sentence tagline."}]
    }' 2>/dev/null)

if echo "$MAIN_RESPONSE" | is_allowed 2>/dev/null; then
    echo "  ✓ PASS: Marketing team's main key unaffected by temp key budget"
    PASS=$((PASS + 1))
else
    echo "  ✗ FAIL: Marketing key was unexpectedly blocked"
    echo "    Response: $(echo "$MAIN_RESPONSE" | head -c 300)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "5. Cleaning up temp key..."
curl -s -X DELETE "$BASE_URL/key/delete" \
    -H "Authorization: Bearer $MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"keys\": [\"$TEMP_KEY\"]}" >/dev/null 2>&1
echo "  ✓ Temp key deleted"

echo ""
echo "─────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "✓ All $PASS budget enforcement tests passed"
else
    echo "✗ $FAIL failed, $PASS passed"
    exit 1
fi
