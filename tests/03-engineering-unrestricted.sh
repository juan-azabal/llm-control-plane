#!/bin/bash
# 03-engineering-unrestricted.sh
#
# DEMONSTRATES: Engineering has no topic control — same questions allowed
# TENANT: engineering (no topic control, minimal rails)
# EXPECTED: All requests pass through, including roadmap questions
#
# Why this matters: ADR-005 — restricting topics for engineers forces shadow AI
# adoption. Invisible usage > visible but restricted usage. Engineers asking
# about the product roadmap may be doing legitimate technical planning.
#
# The control plane exists to ENABLE adoption, not prevent it.
#
# Compare with: 02-marketing-topic-block.sh (same questions, blocked for marketing)

set -euo pipefail

if [ -f .env ]; then export $(grep -v '^#' .env | grep -v '^$' | xargs); fi
if [ -f .env.tenants ]; then export $(grep -v '^#' .env.tenants | grep -v '^$' | xargs); fi

BASE_URL="http://localhost:8080"
KEY="${ENGINEERING_KEY:-}"

if [ -z "$KEY" ]; then
    echo "ERROR: ENGINEERING_KEY not set. Run: bash scripts/setup-tenants.sh"
    exit 1
fi

PASS=0
FAIL=0

is_allowed() { python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if r.get('choices') else 1)"; }

expect_allowed() {
    local name="$1"
    local content="$2"

    response=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"gpt-4o\",
            \"messages\": [{\"role\": \"user\", \"content\": $(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}]
        }" 2>/dev/null)

    if echo "$response" | is_allowed 2>/dev/null; then
        echo "  ✓ ALLOWED: $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ UNEXPECTEDLY BLOCKED: $name"
        echo "    Response: $(echo "$response" | head -c 300)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Engineering Unrestricted Access Tests ==="
echo ""

echo "Topics that would be blocked for Marketing but ALLOWED for Engineering:"
expect_allowed "Roadmap question"     "When is v3 launching? I need to plan the API work."
expect_allowed "Technical features"   "What new capabilities are we building for the next release?"
expect_allowed "Architecture question" "How is our backend API implemented? I need to make it compatible."
expect_allowed "Code request"         "Write a Python function to parse JWT tokens safely."
expect_allowed "Debugging help"       "Help me debug this stack trace: TypeError at line 42, expected str got None."

echo ""
echo "─────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "✓ All $PASS engineering unrestricted tests passed"
else
    echo "✗ $FAIL failed, $PASS passed"
    exit 1
fi
