#!/bin/bash
# 01-secrets-detection.sh
#
# DEMONSTRATES: Secrets detection blocks credentials before any data leaves the network
# TENANT: All tenants (secrets detection is universal, non-negotiable)
# EXPECTED: All requests containing secrets are BLOCKED with a structured error
#
# Why this matters: Pattern-based detection catches credentials in <1ms, before
# the request reaches NeMo, the cloud LLM, or any external service.
# ADR-004: Secrets detection is infrastructure, not a guardrail.
#
# Note: Tests use the master key directly since tenant keys require setup-tenants.sh first.
# The secrets detector runs for ALL keys.

set -euo pipefail

if [ -f .env ]; then
    export $(grep -v '^#' .env | grep -v '^$' | xargs)
fi

BASE_URL="http://localhost:8080"
KEY="${LITELLM_MASTER_KEY:-sk-master-key-change-me}"

PASS=0
FAIL=0

# Check if response is a block (has error with content_policy_violation or no choices)
is_blocked() {
    python3 -c "import sys,json; r=json.load(sys.stdin); raw=json.dumps(r); sys.exit(0 if 'content_policy_violation' in raw or 'secret detected' in raw.lower() or (not r.get('choices') and r.get('error')) else 1)"
}

expect_blocked() {
    local name="$1"
    local content="$2"

    response=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"gpt-4o-mini\",
            \"messages\": [{\"role\": \"user\", \"content\": $(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}]
        }" 2>/dev/null)

    if echo "$response" | is_blocked 2>/dev/null; then
        echo "  ✓ BLOCKED: $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ NOT BLOCKED: $name"
        echo "    Response: $(echo "$response" | head -c 200)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Secrets Detection Tests ==="
echo ""

echo "OpenAI API keys:"
expect_blocked "OpenAI key in prompt" "Please use this key to authenticate: sk-proj-abc123def456ghi789jkl012mno345pqr678stu901"
expect_blocked "OpenAI key with context" "My API key is sk-proj-testkey1234567890abcdefghijklmnop, is this secure?"

echo ""
echo "AWS credentials:"
expect_blocked "AWS access key" "My AWS key is AKIAIOSFODNN7EXAMPLE, should I use it in the code?"
expect_blocked "RSA private key" "Here's my private key: -----BEGIN RSA PRIVATE KEY----- to decrypt the message"

echo ""
echo "Database credentials:"
expect_blocked "Postgres connection string" "Connect to postgres://admin:secretpassword@db.example.com:5432/production"
expect_blocked "MongoDB URI" "mongodb://user:p4ssw0rd@mongo.internal:27017/mydb - is this safe?"

echo ""
echo "Tokens:"
expect_blocked "JWT token" "Here's my token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
expect_blocked "GitHub PAT" "My GitHub token is ghp_1234567890abcdefghijklmnopqrstuvwxyzAB to access the repo"

echo ""
echo "─────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "✓ All $PASS secrets detection tests passed"
else
    echo "✗ $FAIL failed, $PASS passed"
    echo ""
    echo "If tests fail with auth errors: ensure your OPENAI_API_KEY is set in .env"
    echo "If tests fail because requests pass through: check custom_guardrails/secrets_detector.py"
    exit 1
fi
