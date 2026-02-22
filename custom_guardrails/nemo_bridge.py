# NeMo Guardrails Bridge for LiteLLM
#
# This is the core integration between LiteLLM (API gateway) and
# NeMo Guardrails (semantic rail engine). It implements Layer 2 of
# the defense-in-depth architecture.
#
# How it works:
#   1. LiteLLM receives a request with a virtual key (e.g., sk-marketing)
#   2. This guardrail extracts the tenant from the key's team_alias
#   3. It calls NeMo's server API with the tenant's config_id
#   4. NeMo evaluates input rails (topic control, jailbreak detection)
#   5. If NeMo blocks → request is rejected before reaching the cloud LLM
#   6. After the cloud LLM responds, NeMo evaluates output rails
#   7. If output fails → response is replaced with a safe alternative
#
# ADR-003: All NeMo judge calls use local Ollama. No data leaves the network.
# ADR-011: If NeMo is unavailable, fail open (deterministic rails still protect).

import json
import time
import traceback
from typing import Any, Dict, List, Optional, Union

import httpx
from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.types.guardrails import GuardrailEventHooks


class NemoGuardrailBridge(CustomGuardrail):
    """
    Bridges LiteLLM to NeMo Guardrails server for semantic rail evaluation.

    Tenant mapping:
        team_alias → NeMo config_id
        e.g., "marketing" → "marketing" (NeMo config folder name)

    NeMo is called twice per request (if the tenant has semantic rails):
        1. Pre-call: input rails (topic control, jailbreak detection)
        2. Post-call: output rails (output safety, fact-checking)
    """

    def __init__(
        self,
        api_base: Optional[str] = None,
        fail_open: bool = True,
        **kwargs,
    ):
        # Pass supported event hooks to parent
        super().__init__(**kwargs)

        self.nemo_base_url = (api_base or "http://nemo:8000").rstrip("/")
        self.fail_open = fail_open

        # Tenants with NO semantic rails — skip NeMo entirely
        # Engineering has only heuristic jailbreak (handled by NeMo too, but minimal)
        self.skip_tenants: set = set()

        # HTTP client — reused across requests for connection pooling
        self._client: Optional[httpx.AsyncClient] = None

        verbose_proxy_logger.info(
            f"NemoGuardrailBridge initialized: nemo_url={self.nemo_base_url}, "
            f"fail_open={self.fail_open}"
        )

    async def _get_client(self) -> httpx.AsyncClient:
        """Lazy-init HTTP client with connection pooling."""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self.nemo_base_url,
                timeout=httpx.Timeout(30.0, connect=5.0),
            )
        return self._client

    def _get_tenant(self, user_api_key_dict, data: dict) -> Optional[str]:
        """
        Extract tenant identifier from request context.

        Tries team_alias first (human-readable), falls back to team_id.
        Returns None if no tenant can be identified.
        """
        # team_alias is the human-readable team name (e.g., "marketing")
        tenant = getattr(user_api_key_dict, "team_alias", None)
        if tenant:
            return tenant

        # Fallback to team_id
        tenant = getattr(user_api_key_dict, "team_id", None)
        if tenant:
            return tenant

        # Fallback to data dict
        return data.get("user_api_key_team_alias") or data.get("user_api_key_team_id")

    async def _call_nemo(
        self,
        config_id: str,
        messages: List[Dict],
        rails_options: Optional[Dict] = None,
    ) -> Optional[Dict]:
        """
        Call NeMo Guardrails server API.

        Args:
            config_id: NeMo config folder name (e.g., "marketing")
            messages: Conversation messages in OpenAI format
            rails_options: Optional dict to control which rails run
                          e.g., {"input": True, "output": False}

        Returns:
            NeMo response dict, or None if NeMo is unavailable (fail open)
        """
        client = await self._get_client()

        payload: Dict[str, Any] = {
            "config_id": config_id,
            "messages": messages,
        }

        if rails_options:
            payload["options"] = {"rails": rails_options}

        try:
            start = time.time()
            response = await client.post(
                "/v1/chat/completions",
                json=payload,
            )
            duration_ms = (time.time() - start) * 1000

            verbose_proxy_logger.debug(
                f"NeMo response for {config_id}: status={response.status_code}, "
                f"duration={duration_ms:.0f}ms"
            )

            if response.status_code == 200:
                return response.json()
            else:
                verbose_proxy_logger.warning(
                    f"NeMo returned {response.status_code} for config {config_id}: "
                    f"{response.text[:500]}"
                )
                if self.fail_open:
                    return None
                else:
                    raise Exception(
                        f"NeMo guardrail error: {response.status_code}"
                    )

        except httpx.ConnectError:
            verbose_proxy_logger.error(
                f"NeMo is unavailable at {self.nemo_base_url}. "
                f"fail_open={self.fail_open}"
            )
            if self.fail_open:
                return None
            raise
        except httpx.TimeoutException:
            verbose_proxy_logger.error(
                f"NeMo timed out for config {config_id}. "
                f"fail_open={self.fail_open}"
            )
            if self.fail_open:
                return None
            raise
        except Exception as e:
            verbose_proxy_logger.error(
                f"NeMo call failed: {e}\n{traceback.format_exc()}"
            )
            if self.fail_open:
                return None
            raise

    def _is_nemo_refusal(self, nemo_response: Dict) -> Optional[str]:
        """
        Check if NeMo's response indicates a rail was triggered (request blocked).

        NeMo returns a bot message when a rail blocks. We detect this by checking
        if the response content matches known refusal patterns, or if the response
        doesn't contain a typical LLM completion.

        Returns the refusal message if blocked, None if passed.
        """
        messages = nemo_response.get("messages", [])
        if not messages:
            return None

        # Get the last bot message
        last_msg = messages[-1] if messages else {}
        content = last_msg.get("content", "")
        role = last_msg.get("role", "")

        if role != "assistant":
            return None

        # Empty content from NeMo after a user message means a Colang flow
        # executed `stop` without a bot utterance — treat as blocked.
        if not content or not content.strip():
            return "I can't help with that request. It falls outside your team's allowed topics."

        # Check the generation log for activated rails
        log = nemo_response.get("log", {})
        if log:
            activated_rails = log.get("activated_rails", [])
            for rail in activated_rails:
                status = rail.get("status", "")
                if status == "blocked":
                    return content or "Request blocked by content policy."

        # Heuristic: if the response looks like a NeMo-generated refusal
        # (contains typical refusal phrases AND is short), treat it as blocked.
        # Real LLM responses are typically longer than guardrail refusals.
        # Only match short responses (< 300 chars) to avoid false positives on
        # legitimate LLM replies that happen to contain polite refusal language.
        refusal_indicators = [
            "I can't discuss",
            "I cannot discuss",
            "I can't help with that",
            "I cannot help with that",
            "I can't respond to that",
            "I cannot respond to that",
            "I'm sorry, I can't respond",
            "that topic",
            "restricted",
            "I can only help with",
            "outside my scope",
            "inform topic restricted",
            "inform off topic",
            "inform cannot verify",
        ]
        # Only apply heuristic to short responses (guardrail messages are concise)
        if len(content) < 300:
            content_lower = content.lower()
            for indicator in refusal_indicators:
                if indicator.lower() in content_lower:
                    return content

        return None

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ) -> Optional[Union[Exception, str, dict]]:
        """
        Layer 2 input rails: evaluate the user's input before it reaches the cloud LLM.

        Checks: topic control, jailbreak detection (semantic).
        Deterministic checks (secrets, PII, budget) run in Layer 1 before this.
        """
        tenant = self._get_tenant(user_api_key_dict, data)

        if not tenant:
            verbose_proxy_logger.debug(
                "NemoBridge: no tenant identified, skipping"
            )
            return None

        if tenant in self.skip_tenants:
            verbose_proxy_logger.debug(
                f"NemoBridge: tenant {tenant} has no semantic rails, skipping"
            )
            return None

        messages = data.get("messages", [])
        if not messages:
            return None

        verbose_proxy_logger.info(
            f"NemoBridge pre_call: tenant={tenant}, messages={len(messages)}"
        )

        # Call NeMo with input rails only
        nemo_response = await self._call_nemo(
            config_id=tenant,
            messages=messages,
        )

        if nemo_response is None:
            # NeMo unavailable — fail open (ADR-011)
            verbose_proxy_logger.warning(
                f"NemoBridge: NeMo unavailable for tenant {tenant}, "
                "failing open (ADR-011)"
            )
            return None

        # Check if NeMo blocked the request
        refusal = self._is_nemo_refusal(nemo_response)
        if refusal:
            verbose_proxy_logger.info(
                f"NemoBridge: request BLOCKED for tenant {tenant}"
            )
            # Return error string to reject the request
            error_response = json.dumps({
                "error": {
                    "type": "content_policy_violation",
                    "message": refusal,
                    "rail": "nemo_guardrails",
                    "tenant": tenant,
                    "suggestion": "Rephrase your request to stay within your team's allowed topics.",
                }
            })
            return error_response

        verbose_proxy_logger.debug(
            f"NemoBridge pre_call: tenant={tenant} — passed"
        )
        return None

    async def async_post_call_success_hook(
        self,
        data: dict,
        user_api_key_dict,
        response,
    ) -> Any:
        """
        Layer 2 output rails: evaluate the LLM's response before delivering to user.

        Checks: output safety, fact-checking (for support tenant).
        """
        tenant = self._get_tenant(user_api_key_dict, data)

        if not tenant:
            return response

        if tenant in self.skip_tenants:
            return response

        # Extract the LLM's response content
        try:
            if hasattr(response, "choices") and response.choices:
                llm_content = response.choices[0].message.content
            else:
                return response
        except (AttributeError, IndexError):
            return response

        if not llm_content:
            return response

        # Build messages for NeMo output rail check:
        # Include the user's original messages plus the LLM response
        messages = data.get("messages", [])
        messages_with_response = messages + [
            {"role": "assistant", "content": llm_content}
        ]

        verbose_proxy_logger.info(
            f"NemoBridge post_call: tenant={tenant}"
        )

        nemo_response = await self._call_nemo(
            config_id=tenant,
            messages=messages_with_response,
        )

        if nemo_response is None:
            # NeMo unavailable — fail open, return original response
            return response

        # Check if NeMo modified or blocked the output
        nemo_messages = nemo_response.get("messages", [])
        if nemo_messages:
            last_msg = nemo_messages[-1]
            nemo_content = last_msg.get("content", "")

            # If NeMo returned different content, it means output rails triggered
            if nemo_content and nemo_content != llm_content:
                verbose_proxy_logger.info(
                    f"NemoBridge: output rail triggered for tenant {tenant}, "
                    "replacing response"
                )
                # Modify the response in place
                if hasattr(response, "choices") and response.choices:
                    response.choices[0].message.content = nemo_content

        return response
