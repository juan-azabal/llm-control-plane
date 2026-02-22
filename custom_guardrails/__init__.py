# Custom guardrails for LLM Control Plane
#
# This package contains LiteLLM CustomGuardrail subclasses that implement
# the three-layer defense architecture:
#
# Layer 1 (deterministic):
#   - secrets_detector.py  — regex-based secrets detection, runs first, all tenants
#   - pii_detector.py      — PII detection with per-tenant behavior (strip/warn/strip_hard)
#
# Layer 2 (semantic):
#   - nemo_bridge.py       — bridges LiteLLM to NeMo Guardrails server for semantic rails
