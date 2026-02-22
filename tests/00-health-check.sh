#!/bin/bash
# 00-health-check.sh
#
# DEMONSTRATES: All four services are running and healthy
# EXPECTED: All health checks pass
#
# Run this first before any other tests to verify the stack is up.

set -euo pipefail

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Health Check ==="
echo ""

echo "Docker containers:"
check "Ollama running"   "docker exec llm-control-plane-ollama-1 ollama list"
check "NeMo running"    "curl -sf http://localhost:8001/v1/rails/configs"
check "LiteLLM running" "curl -sf http://localhost:8080/ -o /dev/null"
check "Postgres running" "docker exec llm-control-plane-postgres-1 pg_isready -U litellm"

echo ""
echo "Ollama model:"
check "llama3.2:3b loaded" "docker exec llm-control-plane-ollama-1 ollama list | grep -q llama3.2"

echo ""
echo "NeMo configs:"
check "marketing config" "curl -sf http://localhost:8001/v1/rails/configs | grep -q marketing"
check "engineering config" "curl -sf http://localhost:8001/v1/rails/configs | grep -q engineering"
check "support config" "curl -sf http://localhost:8001/v1/rails/configs | grep -q support"

echo ""
echo "─────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "✓ All $PASS checks passed"
else
    echo "✗ $FAIL failed, $PASS passed"
    echo ""
    echo "Troubleshooting:"
    echo "  docker compose ps"
    echo "  docker compose logs [service]"
    exit 1
fi
