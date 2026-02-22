#!/bin/bash
# 09-fail-open.sh
#
# DEMONSTRATES: When NeMo (semantic rails) goes down, requests still pass through
# TENANT: marketing (would normally have topic control)
# EXPECTED: Requests succeed even with NeMo unavailable (ADR-011)
#
# Why this matters: The deterministic rails (secrets, PII, budget) still protect.
# The residual risk of semantic rail bypass during a short outage is lower than
# blocking Marketing and Support entirely.
#
# ADR-011: Fail open with immediate alert escalation.
# Invalidation signal: a security incident during fail-open that semantic rails
# would have caught.
#
# This test: stop NeMo → send request → verify it passes → restart NeMo

set -euo pipefail

if [ -f .env ]; then export $(grep -v '^#' .env | grep -v '^$' | xargs); fi
if [ -f .env.tenants ]; then export $(grep -v '^#' .env.tenants | grep -v '^$' | xargs); fi

BASE_URL="http://localhost:8080"
KEY="${MARKETING_KEY:-}"

if [ -z "$KEY" ]; then
    echo "ERROR: MARKETING_KEY not set. Run: bash scripts/setup-tenants.sh"
    exit 1
fi

is_allowed() { python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if r.get('choices') else 1)"; }

echo "=== Fail-Open Test (ADR-011) ==="
echo ""
echo "This test stops the NeMo container and verifies requests still succeed."
echo ""

echo "1. Verifying NeMo is currently running..."
if ! curl -sf http://localhost:8001/v1/rails/configs &>/dev/null; then
    echo "   NeMo is not running. Start it first: docker compose start nemo"
    exit 1
fi
echo "   ✓ NeMo is running"

echo ""
echo "2. Stopping NeMo container..."
docker compose stop nemo
echo "   ✓ NeMo stopped"

echo ""
echo "3. Sending request while NeMo is down..."
sleep 2  # Give LiteLLM time to notice the connection will fail

response=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Write a one-sentence product tagline."}]
    }' 2>/dev/null)

if echo "$response" | is_allowed 2>/dev/null; then
    echo "   ✓ PASS: Request succeeded while NeMo was down (fail open)"
else
    echo "   ✗ FAIL: Request was blocked when NeMo went down"
    echo "     Response: $(echo "$response" | head -c 300)"
    echo ""
    echo "   Restarting NeMo..."
    docker compose start nemo
    exit 1
fi

echo ""
echo "4. Restarting NeMo..."
docker compose start nemo
echo "   ✓ NeMo restarted"

echo ""
echo "5. Verifying NeMo is healthy again..."
for i in $(seq 1 15); do
    if curl -sf http://localhost:8001/v1/rails/configs &>/dev/null; then
        echo "   ✓ NeMo is healthy"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "   WARNING: NeMo did not recover in 15 attempts"
    fi
    sleep 2
done

echo ""
echo "─────────────────────────────"
echo "✓ Fail-open behavior verified (ADR-011)"
echo ""
echo "Note: In production, this should trigger an immediate alert."
echo "Deterministic rails (secrets, PII, budget) were still active during the outage."
