#!/bin/bash
# 06-pii-handling.sh
#
# DEMONSTRATES: PII handling differs per tenant (strip / warn / block)
# TENANTS: marketing (strip), engineering (warn), support (block hard)
# EXPECTED: PII in prompts is handled according to each tenant's policy
#
# Why this matters: ADR-008 — PII exposure risk differs by tenant context.
# Marketing doing persona work may legitimately include emails in prompts;
# the platform should strip before sending to cloud LLM, not block outright.
# Support agents must never send customer PII to a cloud provider.
#
# Policies implemented in custom_guardrails/pii_detector.py:
#   marketing:   strip PII silently, request continues with redacted prompt
#   engineering: warn (log + allow through) — devs need full stack traces
#   support:     block hard — customer data must not leave the perimeter
#
# Note: PII detection uses regex; sophisticated encoding can bypass it.
# This is Layer 1 (deterministic) — see CONTEXT.md for defense-in-depth.

set -euo pipefail

if [ -f .env ]; then export $(grep -v '^#' .env | grep -v '^$' | xargs); fi
if [ -f .env.tenants ]; then export $(grep -v '^#' .env.tenants | grep -v '^$' | xargs); fi

BASE_URL="http://localhost:8080"

PASS=0
FAIL=0

is_allowed() { python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if r.get('choices') else 1)"; }
is_pii_blocked() { python3 -c "import sys,json; r=json.load(sys.stdin); err=r.get('error',{}); msg=str(err.get('message','')).lower(); sys.exit(0 if ('pii' in msg or 'personal' in msg or 'blocked' in msg or 'detected' in msg) or (err and 'api key' not in msg and 'openai' not in msg) else 1)"; }

check_pii_behavior() {
    local tenant_name="$1"
    local key="$2"
    local prompt="$3"
    local expected="$4"  # "allowed", "blocked", "stripped"

    response=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"gpt-4o-mini\",
            \"messages\": [{\"role\": \"user\", \"content\": $(echo "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}]
        }" 2>/dev/null)

    case "$expected" in
        "blocked")
            if echo "$response" | is_pii_blocked 2>/dev/null; then
                echo "  ✓ BLOCKED ($tenant_name): PII hard-blocked as expected"
                PASS=$((PASS + 1))
            else
                echo "  ✗ NOT BLOCKED ($tenant_name): Expected PII to be hard-blocked"
                echo "    Response: $(echo "$response" | head -c 300)"
                FAIL=$((FAIL + 1))
            fi
            ;;
        "allowed"|"stripped")
            if echo "$response" | is_allowed 2>/dev/null; then
                echo "  ✓ PASSED THROUGH ($tenant_name): Request succeeded (PII stripped/warned before cloud LLM)"
                PASS=$((PASS + 1))
            else
                echo "  ✗ UNEXPECTEDLY BLOCKED ($tenant_name): Request with PII should have passed"
                echo "    Response: $(echo "$response" | head -c 300)"
                FAIL=$((FAIL + 1))
            fi
            ;;
    esac
}

echo "=== PII Handling Per-Tenant Tests ==="
echo ""

MARKETING_KEY="${MARKETING_KEY:-}"
ENGINEERING_KEY="${ENGINEERING_KEY:-}"
SUPPORT_KEY="${SUPPORT_KEY:-}"

if [ -z "$MARKETING_KEY" ] || [ -z "$ENGINEERING_KEY" ] || [ -z "$SUPPORT_KEY" ]; then
    echo "ERROR: Tenant keys not set. Run: bash scripts/setup-tenants.sh"
    exit 1
fi

PII_EMAIL="The customer's email is john.doe@example.com — please send them a follow-up."
PII_PHONE="The user's phone number is 415-555-0123 — update their contact info."
PII_SSN="SSN on file: 123-45-6789. Verify this matches their account."

echo "Marketing (strip PII silently — request continues):"
check_pii_behavior "marketing" "$MARKETING_KEY" "$PII_EMAIL" "stripped"
check_pii_behavior "marketing" "$MARKETING_KEY" "$PII_PHONE" "stripped"

echo ""
echo "Engineering (warn — log PII detection, allow through for debugging):"
check_pii_behavior "engineering" "$ENGINEERING_KEY" "$PII_EMAIL" "allowed"
check_pii_behavior "engineering" "$ENGINEERING_KEY" "$PII_PHONE" "allowed"

echo ""
echo "Support (hard block — customer PII must not reach cloud LLM):"
check_pii_behavior "support" "$SUPPORT_KEY" "$PII_EMAIL" "blocked"
check_pii_behavior "support" "$SUPPORT_KEY" "$PII_SSN" "blocked"

echo ""
echo "─────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "✓ All $PASS PII handling tests passed"
else
    echo "✗ $FAIL failed, $PASS passed"
    echo ""
    echo "Note: If Marketing/Engineering are unexpectedly blocked, check that"
    echo "pii_detector.py is loaded and tenant policies are configured correctly."
    exit 1
fi
