# Secrets Detection Guardrail
#
# Layer 1, runs FIRST, before all other processing.
# ADR-004: Secrets detection is infrastructure, not a guardrail.
#
# Deterministic (regex), universal (all tenants), $0 cost, <1ms latency.
# On match: request is BLOCKED. No data forwarded. Error never contains the secret.

import os
import re
from typing import Any, Dict, List, Optional, Union

import yaml
from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_guardrail import CustomGuardrail


class SecretsDetector(CustomGuardrail):
    """
    Regex-based secrets detection that runs before all other guardrails.

    Loads patterns from secrets/patterns.yaml and scans all message content.
    On match: blocks the request with a structured error that identifies
    the pattern type but NEVER includes the matched secret.
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        self._patterns: List[Dict[str, Any]] = []
        self._load_patterns()

        verbose_proxy_logger.info(
            f"SecretsDetector initialized: {len(self._patterns)} patterns loaded"
        )

    def _load_patterns(self):
        """Load regex patterns from secrets/patterns.yaml."""
        # Try multiple paths — depends on working directory
        candidate_paths = [
            "/app/secrets/patterns.yaml",
            "secrets/patterns.yaml",
            os.path.join(os.path.dirname(__file__), "..", "secrets", "patterns.yaml"),
        ]

        for path in candidate_paths:
            if os.path.exists(path):
                with open(path, "r") as f:
                    data = yaml.safe_load(f)

                for pattern_def in data.get("patterns", []):
                    try:
                        compiled = re.compile(pattern_def["regex"])
                        self._patterns.append({
                            "name": pattern_def["name"],
                            "regex": compiled,
                            "description": pattern_def.get("description", ""),
                        })
                    except re.error as e:
                        verbose_proxy_logger.error(
                            f"SecretsDetector: invalid regex for "
                            f"'{pattern_def['name']}': {e}"
                        )

                verbose_proxy_logger.info(
                    f"SecretsDetector: loaded {len(self._patterns)} patterns from {path}"
                )
                return

        verbose_proxy_logger.warning(
            "SecretsDetector: no patterns file found. "
            "Tried: " + ", ".join(candidate_paths)
        )

    def _extract_text(self, data: dict) -> str:
        """Extract all text content from the request for scanning."""
        texts = []

        messages = data.get("messages", [])
        for msg in messages:
            content = msg.get("content", "")
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                # Handle multimodal messages
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        texts.append(part.get("text", ""))

        return "\n".join(texts)

    def _scan(self, text: str) -> Optional[Dict[str, str]]:
        """
        Scan text for secrets.

        Returns the first matching pattern info, or None if clean.
        """
        for pattern in self._patterns:
            if pattern["regex"].search(text):
                return {
                    "name": pattern["name"],
                    "description": pattern["description"],
                }
        return None

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ) -> Optional[Union[Exception, str, dict]]:
        """
        Scan input for secrets. Block immediately on match.

        This runs BEFORE NeMo guardrails, BEFORE the LLM call.
        ADR-004: universal, non-negotiable, all tenants.
        """
        text = self._extract_text(data)
        if not text:
            return None

        match = self._scan(text)
        if match:
            tenant = (
                getattr(user_api_key_dict, "team_alias", None)
                or getattr(user_api_key_dict, "team_id", None)
                or "unknown"
            )

            verbose_proxy_logger.warning(
                f"SecretsDetector: BLOCKED request for tenant={tenant}, "
                f"pattern={match['name']}. No data forwarded."
            )

            # Return error string — this rejects the request.
            # NEVER include the matched content in the error.
            import json
            return json.dumps({
                "error": {
                    "type": "content_policy_violation",
                    "message": (
                        f"Request blocked: potential secret detected "
                        f"(type: {match['name']}). "
                        f"No data was sent to the LLM provider. "
                        f"Remove the credential and retry."
                    ),
                    "rail": "secrets_detection",
                    "tenant": tenant,
                }
            })

        return None
