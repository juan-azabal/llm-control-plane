# ADR-001: Use LiteLLM as the API Gateway

**Status:** Accepted

## Context

We need a proxy that sits between business teams and cloud LLMs. It must: route by model, enforce budgets, support virtual keys per team, and allow custom middleware (guardrails). The alternatives were:

- Build a custom FastAPI proxy
- Use LiteLLM (open source, 20k+ GitHub stars)
- Use a managed service (OpenAI Enterprise, Azure AI Foundry)

## Decision

Use **LiteLLM** as the gateway layer.

## Rationale

1. **Zero-effort OpenAI compatibility.** LiteLLM exposes an OpenAI-compatible API. Teams need zero code changes — they just point their `OPENAI_BASE_URL` at our proxy.

2. **Built-in budget enforcement.** Postgres-backed spend tracking with per-team hard/soft caps. This is non-trivial to build correctly — LiteLLM has battle-tested it.

3. **Virtual key management.** Team isolation via virtual keys that map to budget pools and model allowlists. The UI and API for key management are already built.

4. **CustomGuardrail extensibility.** LiteLLM provides a `CustomGuardrail` base class with `async_pre_call_hook` and `async_post_call_success_hook`. This is exactly the integration point we need to inject NeMo.

5. **Active maintenance.** The LiteLLM team ships updates weekly. A custom proxy would become technical debt immediately.

## Trade-offs Accepted

- **Version pinning risk.** `main-latest` is fast-moving. The `CustomGuardrail` API could change. Mitigation: pin to a specific digest after validating.
- **Dependency on third-party.** We're betting on an open-source project. Mitigation: the custom guardrail code is our own; we can swap the gateway if needed.
- **Opaque internals.** When something breaks in LiteLLM's routing, debugging requires reading source. Mitigation: extensive logging.

## Invalidation Signal

If LiteLLM's `CustomGuardrail` API changes in a breaking way and is not backwards-compatible within a reasonable migration window, reconsider building a thin custom proxy that imports LiteLLM's routing logic as a library.
