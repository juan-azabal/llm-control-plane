#!/bin/bash
# run-all.sh
#
# Runs all test scripts in sequence and produces a summary report.
# Each test script is self-documenting — read them to understand what's being tested.
#
# Usage:
#   bash tests/run-all.sh
#
# Prerequisites:
#   - All services running (docker compose up -d)
#   - Ollama model pulled (bash scripts/init-ollama.sh)
#   - Tenants created (bash scripts/setup-tenants.sh)
#   - .env with OPENAI_API_KEY set
#   - .env.tenants with MARKETING_KEY, ENGINEERING_KEY, SUPPORT_KEY

set -euo pipefail

PASS=0
FAIL=0
SKIP=0

run_test() {
    local script="$1"
    local name="$(basename "$script" .sh)"
    echo ""
    echo "━━━ $name ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if bash "$script"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════════"
echo "  LLM Control Plane — Test Suite"
echo "═══════════════════════════════════════════════"

# Run tests in dependency order
run_test tests/00-health-check.sh
run_test tests/01-secrets-detection.sh

# Tenant-specific tests require setup-tenants.sh
if [ -f .env.tenants ]; then
    run_test tests/02-marketing-topic-block.sh
    run_test tests/03-engineering-unrestricted.sh
    run_test tests/04-support-topic-allow.sh
    run_test tests/05-support-factcheck.sh
    run_test tests/06-pii-handling.sh
    run_test tests/07-budget-enforcement.sh
    run_test tests/08-jailbreak-detection.sh
else
    echo ""
    echo "━━━ SKIPPED: Tenant tests ━━━━━━━━━━━━━━━━━━━━"
    echo "  .env.tenants not found. Run: bash scripts/setup-tenants.sh"
    SKIP=$((SKIP + 7))
fi

# Fail-open test last (it stops/starts containers)
# Only run if explicitly requested
if [ "${RUN_FAILOPEN:-false}" = "true" ]; then
    run_test tests/09-fail-open.sh
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  Test Results"
echo "═══════════════════════════════════════════════"
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
[ "$SKIP" -gt 0 ] && echo "  Skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "  ✗ Some tests failed."
    exit 1
else
    echo "  ✓ All tests passed."
fi
