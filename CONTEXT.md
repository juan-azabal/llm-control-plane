# LLM Control Plane — Developer Context

This file is the onboarding document for anyone (human or AI assistant) working on this codebase. Read it before touching anything.

---

## What This Is

An enterprise AI governance layer. It sits between your business teams and cloud LLMs, enforcing per-tenant policies without requiring teams to change their OpenAI-compatible API calls.

The three open-source components are:
- **LiteLLM** — API gateway, routing, budget enforcement, virtual keys
- **NeMo Guardrails** — semantic policy engine (Colang 1.0 DSL, `self_check_input` rail)
- **Ollama + Llama 3.2 3B** — local judge LLM (installed, ready; currently unused in MVP)

**Current MVP judge:** gpt-4o-mini (OpenAI) powers the NeMo `self_check_input` rail. This was chosen for MVP to validate the full stack quickly. Ollama 3B is the target for production cost reduction — it's pre-installed and the switch is a one-line config change per `guardrails/*/config.yml`. See ADR-003.

---

## Stack Invariants

These are non-negotiable. Violating them breaks the security model.

1. **Sensitive data never reaches the cloud.** Layer 1 (deterministic) runs before NeMo. Only clean, scrubbed requests reach OpenAI.

2. **Secrets detection runs before everything else.** In `litellm-config.yaml`, `secrets-detection` must appear before `nemo-guardrails` in the `guardrails:` list. LiteLLM processes them in order.

3. **Fail open, not closed (ADR-011).** If NeMo goes down, requests pass through. Deterministic rails still protect. An alert must fire (not implemented in this demo, but documented).

4. **NeMo is the semantic layer only.** Budget enforcement, PII handling, and secrets detection live in LiteLLM/custom code. NeMo should not be used for things it can't do reliably.

5. **Colang 1.0, not 2.0.** NeMo Guardrails has two incompatible DSL versions. This project uses 1.0. Do not upgrade to 2.0 without testing all Colang flows — they are not compatible.

6. **Active rails use `self_check_input` only.** Colang flows in `.co` files are reference/documentation. In NeMo server mode, Colang flows execute as chatbot-turn conversations, not as semantic evaluators. The `self_check_input` built-in rail (driven by `prompts.yml`) is what actually runs. Do not add Colang flows to the `rails.input.flows` list expecting them to act as topic evaluators — they won't.

---

## File Structure (What Does What)

```
litellm-config.yaml         ← Start here. Model routing, guardrail order, env refs.
custom_guardrails/
  secrets_detector.py       ← Layer 1a. Runs for ALL tenants. Returns error string to block.
  pii_detector.py           ← Layer 1b. Tenant-specific behavior (strip/warn/block).
  nemo_bridge.py            ← Layer 2. Calls NeMo HTTP API. Maps team_alias → config_id.
secrets/patterns.yaml       ← Regex patterns. Add new patterns here.
guardrails/<tenant>/        ← NeMo configs per tenant.
  config.yml                ← NeMo engine config (models, rails enabled).
  prompts.yml               ← THE ACTIVE POLICY. self_check_input prompt per tenant.
  config.co                 ← Colang flows (reference/documentation only — NOT active in MVP).
  kb/                       ← Knowledge base for fact-checking (support only — wiring deferred to v2).
```

**What's active vs deferred in the MVP:**

| Component | Status | Location |
|-----------|--------|----------|
| `self_check_input` rail | ✅ Active (all tenants) | `guardrails/*/prompts.yml` |
| Secrets detection | ✅ Active | `custom_guardrails/secrets_detector.py` |
| PII detection | ✅ Active | `custom_guardrails/pii_detector.py` |
| Budget enforcement | ✅ Active | LiteLLM built-in, Postgres |
| Colang flows | ⏸ Reference only | `guardrails/*/config.co` |
| Output safety rails | ⏸ Deferred (v2) | Not configured in any `config.yml` |
| Fact-checking | ⏸ Deferred (v2) | KB exists, not wired to NeMo |
| Ollama as judge | ⏸ Ready, not active | `scripts/init-ollama.sh` pulls the model |

---

## How LiteLLM Loads Custom Guardrails

LiteLLM resolves dotted module paths relative to the config file directory. Since config is at `/app/config.yaml` inside the container, `custom_guardrails.secrets_detector.SecretsDetector` resolves to `/app/custom_guardrails/secrets_detector.py`.

The Docker mount is: `./custom_guardrails:/app/custom_guardrails`

**Class interface** (from `litellm.integrations.custom_guardrail.CustomGuardrail`):

```python
async def async_pre_call_hook(
    self,
    user_api_key_dict: UserAPIKeyAuth,
    cache: DualCache,
    data: dict,           # The full request body
    call_type: str
) -> Optional[str]:       # Return a string to BLOCK (becomes the error message)
    ...

async def async_post_call_success_hook(
    self,
    data: dict,
    user_api_key_dict: UserAPIKeyAuth,
    response                            # ModelResponse object
) -> Any:
    ...
```

Returning a non-empty string from `async_pre_call_hook` blocks the request and returns that string as the error message. Returning `None` passes through.

---

## How Tenant Identity Works

When a virtual key is used, LiteLLM populates `UserAPIKeyAuth` with the team info. In `nemo_bridge.py`:

```python
tenant = user_api_key_dict.team_alias  # "marketing", "engineering", "support"
```

This maps to the NeMo config directory name (`guardrails/<tenant>/`), which is the `config_id` NeMo expects.

Teams are created via `scripts/setup-tenants.sh` which calls the LiteLLM REST API (`POST /team/new`). Keys are then generated per team (`POST /key/generate`). Both are stored in Postgres.

---

## How NeMo Works

NeMo runs as a separate HTTP server (port 8000, internal). The bridge calls:

```
POST http://nemo:8000/v1/chat/completions
Content-Type: application/json

{
  "model": "<config_id>",   ← maps to guardrails/<config_id>/
  "messages": [...],
  "config_id": "<config_id>"
}
```

NeMo runs the `self_check_input` built-in flow (configured in `guardrails/<tenant>/config.yml`). The flow:
1. Calls the judge LLM with the tenant's prompt from `prompts.yml`
2. If the judge answers "Yes" (block), NeMo returns its default refusal: `"I'm sorry, I can't respond to that."`
3. If the judge answers "No" (allow), NeMo returns an empty or pass-through response

**Refusal detection in `nemo_bridge.py`:**
- Empty response content → Colang `stop` executed → treat as blocked
- Short response (<300 chars) containing a refusal phrase → treat as blocked
- Long response (≥300 chars) → treat as allowed (legitimate LLM reply, not a guardrail message)

The 300-char length gate prevents false positives where a helpful LLM reply starts with "I'm unable to..." but continues with useful content.

---

## Colang 1.0 Quick Reference

NeMo policy files use Colang 1.0 (`.co` files):

```colang
# Define what a topic looks like
define user ask about roadmap
  "when is v3 launching"
  "upcoming features"
  "what's on the roadmap"

# Define a flow (policy rule)
define flow block roadmap topics
  user ask about roadmap
  bot refuse to discuss roadmap

# Define what the bot says
define bot refuse to discuss roadmap
  "I can't discuss internal roadmap information."
```

**Key patterns:**
- `define user <label>` — example utterances (LLM generalizes from these)
- `define flow <name>` — policy rule (if user does X, bot does Y)
- `define bot <label>` — response template
- `define subflow <name>` — reusable flow fragment

The `config.yml` controls which rails run (input/output/retrieval) and which models power them.

---

## What NOT to Do

- **Don't add PII to NeMo configs.** NeMo logs to stdout. Custom guardrail code handles PII before NeMo sees it.
- **Don't commit `.env` or `.env.tenants`.** Both are in `.gitignore`. They contain API keys.
- **Don't restart NeMo mid-request.** NeMo caches rail configs on startup. If you change a `.co` or `.yml` file, restart the NeMo container.
- **Don't assume guardrail execution order.** Always verify by checking LiteLLM startup logs for the callback chain order.
- **Don't use Colang 2.0 syntax.** The `nemoguardrails` version installed uses 1.0. Colang 2.0 is a different, incompatible language.
- **Don't add the Ollama model URL as an OpenAI `api_base` without the `/v1` suffix.** NeMo's OpenAI-compatible engine expects `http://ollama:11434/v1`, not `http://ollama:11434`.
- **Don't add Colang flows to `rails.input.flows` expecting semantic evaluation.** In NeMo server mode, Colang flows are chatbot-turn flows that match on exact intent patterns. Use `self check input` with a custom prompt in `prompts.yml` instead.
- **Don't set the budget too high for budget tests.** gpt-4o-mini costs ~$0.0003/request. The test uses `max_budget: 0.0001` to guarantee exhaustion in a single request. A larger value may not exhaust in one call.

---

## Common Operations

### Restart after config changes

```bash
# After editing litellm-config.yaml or custom_guardrails/*.py
docker compose restart litellm

# After editing guardrails/**/*.co or guardrails/**/*.yml
docker compose restart nemo
```

### View guardrail decisions

```bash
docker compose logs litellm --follow  # See SecretsDetector and NemoGuardrailBridge logs
docker compose logs nemo --follow     # See which flows activated
```

### Check NeMo loaded configs

```bash
curl http://localhost:8000/v1/rails/configs
```

### Regenerate tenant keys

```bash
bash scripts/setup-tenants.sh
```

This creates new teams and keys. Old keys remain valid unless explicitly deleted.

---

## Known Limitations

1. **gpt-4o-mini as judge (MVP cost).** The current judge model is gpt-4o-mini, which adds API cost per guarded request. This was chosen for MVP accuracy. The production target is Ollama + Llama 3.2 3B (zero marginal cost). Switching is a config change — see README for instructions.

2. **NeMo latency.** Each request that hits NeMo adds 1–5 seconds (gpt-4o-mini judge). With Ollama 3B on CPU, this rises to 5–30 seconds. On GPU, both drop to <1s.

3. **Fact-checking not active.** `self_check_facts` output rail is deferred. The support KB exists (`guardrails/support/kb/`) but is not wired. `tests/05-support-factcheck.sh` tests are marked non-blocking as a result.

4. **Output safety rails not active.** `self_check_output` is not configured for any tenant. Only input rails (`self_check_input`) are active in the MVP.

5. **Colang flows are reference-only.** The `.co` files describe the intended policy in a readable format but are not executed as input rail evaluators. Policy logic lives in `prompts.yml`.

6. **No streaming support.** LiteLLM streaming with custom guardrails has limitations. Streaming is disabled for guarded requests.

7. **Single-node only.** No horizontal scaling designed for this demo. LiteLLM supports Redis for distributed deployments (ADR-002).

---

## Dependencies

| Service | Image | Why This Version |
|---------|-------|-----------------|
| LiteLLM | `ghcr.io/berriai/litellm:main-latest` | Latest has CustomGuardrail API |
| NeMo | Custom `Dockerfile.nemo` | No official image exists |
| Ollama | `ollama/ollama:latest` | Standard Ollama image |
| Postgres | `postgres:16-alpine` | LiteLLM's required backend |

The NeMo image builds from `python:3.11-slim` and installs:
- `nemoguardrails` — the guardrails engine
- `langchain-openai` — required for gpt-4o-mini judge (current MVP)
- `langchain-ollama` — required for Ollama/Llama 3.2 3B judge (production target)
- `aiohttp` — async HTTP client for internal calls
