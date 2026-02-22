# PII Detector for LiteLLM
#
# Per-tenant PII handling policy (ADR-008):
#   marketing:   strip PII silently — request continues with redacted prompt
#   engineering: warn — log detection, allow through (devs need full stack traces)
#   support:     block hard — customer data must not reach cloud LLM
#
# PII detected: email addresses, US phone numbers, SSNs
#
# Layer: 1 (deterministic, regex, <1ms). Runs after secrets detection.
# Limitation: regex only — sophisticated encoding can bypass. Not a substitute
# for proper data governance. See docs/decisions/008-pii-handling.md.

import re
from typing import Any, Optional, Union

from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_guardrail import CustomGuardrail

# ─── PII Patterns ──────────────────────────────────────────────────────────
# Ordered from most specific to least to avoid false positives.

_PII_PATTERNS = [
    ("ssn",   re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    ("email", re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")),
    ("phone", re.compile(r"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b")),
]

# Replacement tokens for strip mode
_REPLACEMENTS = {
    "ssn":   "[SSN REDACTED]",
    "email": "[EMAIL REDACTED]",
    "phone": "[PHONE REDACTED]",
}


def _detect_pii(text: str) -> list[tuple[str, str]]:
    """Return list of (pii_type, matched_value) found in text."""
    found = []
    for pii_type, pattern in _PII_PATTERNS:
        for match in pattern.finditer(text):
            found.append((pii_type, match.group()))
    return found


def _strip_pii(text: str) -> str:
    """Replace all PII in text with redaction tokens."""
    for pii_type, pattern in _PII_PATTERNS:
        text = pattern.sub(_REPLACEMENTS[pii_type], text)
    return text


class PIIDetector(CustomGuardrail):
    """
    PII detection and per-tenant enforcement for LiteLLM.

    Tenant policies:
        marketing   → strip: redact PII, continue request
        engineering → warn: log, allow through unchanged
        support     → block: reject request entirely

    Default (unknown tenant) → strip (conservative fallback).
    """

    TENANT_POLICIES = {
        "marketing":   "strip",
        "engineering": "warn",
        "support":     "block",
    }
    DEFAULT_POLICY = "strip"

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        verbose_proxy_logger.info("PIIDetector initialized")

    def _get_tenant(self, user_api_key_dict, data: dict) -> Optional[str]:
        tenant = getattr(user_api_key_dict, "team_alias", None)
        if tenant:
            return tenant
        return data.get("user_api_key_team_alias") or data.get("user_api_key_team_id")

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ) -> Optional[Union[Exception, str, dict]]:
        """
        Inspect user messages for PII and apply tenant policy.

        Returns:
            None     — request passes (no PII, or policy=warn)
            dict     — modified data with PII stripped (policy=strip)
            str      — JSON error string to block the request (policy=block)
        """
        messages = data.get("messages", [])
        if not messages:
            return None

        tenant = self._get_tenant(user_api_key_dict, data) or ""
        policy = self.TENANT_POLICIES.get(tenant, self.DEFAULT_POLICY)

        # Scan all user messages
        all_pii: list[tuple[str, str]] = []
        for msg in messages:
            if msg.get("role") == "user":
                content = msg.get("content", "")
                if isinstance(content, str):
                    all_pii.extend(_detect_pii(content))

        if not all_pii:
            return None

        pii_types = sorted({t for t, _ in all_pii})
        verbose_proxy_logger.info(
            f"PIIDetector: tenant={tenant or '(unknown)'} policy={policy} "
            f"detected={pii_types}"
        )

        if policy == "warn":
            # Log and allow — engineer may legitimately need full stack traces
            verbose_proxy_logger.warning(
                f"PIIDetector WARN: PII in engineering request: {pii_types}. "
                "Allowing through per tenant policy."
            )
            return None

        if policy == "strip":
            # Redact PII in place, continue with modified data
            new_messages = []
            for msg in messages:
                if msg.get("role") == "user":
                    content = msg.get("content", "")
                    if isinstance(content, str):
                        stripped = _strip_pii(content)
                        new_messages.append({**msg, "content": stripped})
                    else:
                        new_messages.append(msg)
                else:
                    new_messages.append(msg)
            data["messages"] = new_messages
            verbose_proxy_logger.info(
                f"PIIDetector STRIP: redacted {pii_types} for tenant={tenant}"
            )
            return None  # Modified data in place; return None to continue

        if policy == "block":
            import json
            error_response = json.dumps({
                "error": {
                    "type": "content_policy_violation",
                    "message": (
                        f"Request blocked: personal data detected ({', '.join(pii_types)}). "
                        "Customer PII must not be sent to this service. "
                        "Remove personal information before retrying."
                    ),
                    "rail": "pii_detector",
                    "tenant": tenant,
                    "detected_types": pii_types,
                    "suggestion": "Remove PII from your request before retrying.",
                    "docs": "https://github.com/your-org/llm-control-plane/blob/main/docs/decisions/008-pii-handling.md",
                }
            })
            return error_response

        return None
