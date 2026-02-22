# LLM Control Plane

An enterprise AI governance layer that routes, guards, and governs LLM usage across business teams — each with different risk profiles, budgets, and content policies.

**Stack:** LiteLLM (gateway) · NeMo Guardrails (semantic rails) · Ollama + Llama 3.2 3B (local judge) · Docker Compose

> **Privacy-by-design:** To evaluate whether a query is harmful or off-topic, the judge model must read it in full. If the judge is a cloud model, every employee query — including sensitive ones — is transmitted externally *before* it's decided whether to block it. Ollama keeps evaluation on-network: only policy-compliant requests reach the cloud LLM. Benchmark: engineering 100% F1, marketing 94.7%, support 90.8%. See [ADR-003](docs/decisions/003-local-judge-ollama.md).

---

## See It Work in 10 Minutes

### Prerequisites

- Docker Desktop running
- OpenAI API key

### 1. Clone and configure

```bash
git clone <this-repo>
cd llm-control-plane
cp .env.example .env
# Edit .env — add your OPENAI_API_KEY
```

### 2. Start everything

```bash
docker compose up -d
```

Wait ~60 seconds for all services to initialize, then:

```bash
# Create tenant teams + virtual keys
bash scripts/setup-tenants.sh
```

> **Required on first run:** Pull the Ollama judge model (~2GB, one-time):
> ```bash
> bash scripts/init-ollama.sh
> ```

### 3. Run the test suite

```bash
bash tests/run-all.sh
```

All tests should pass. You'll see:
- Secrets blocked before reaching the cloud
- Marketing's roadmap questions blocked (semantic, no keywords)
- Engineering's same questions allowed
- Support's off-topic requests redirected
- Budget enforcement cutting off over-limit keys

---

## Architecture

```
[Client Request]
      │
      ▼
┌─────────────────────────────────────────────────┐
│                  LiteLLM Gateway                │  :8080
│                                                 │
│  Layer 1 — Deterministic Rails (all tenants)   │
│  ┌──────────────┐  ┌─────────────────────────┐ │
│  │ Secrets Det. │  │ PII Detector            │ │
│  │ (regex, <1ms)│  │ (strip/warn/block)      │ │
│  └──────────────┘  └─────────────────────────┘ │
│  ┌──────────────┐                               │
│  │ Budget Guard │  (LiteLLM built-in, Postgres) │
│  └──────────────┘                               │
│                                                 │
│  Layer 2 — Semantic Rails (per-tenant policy)  │
│  ┌─────────────────────────────────────────┐   │
│  │       NeMo Guardrails Bridge            │   │
│  │  marketing: block-list topics           │   │
│  │  engineering: jailbreak only            │   │
│  │  support: allow-list topics             │   │
│  └───────────────┬─────────────────────────┘   │
│                  │ HTTP                          │
└──────────────────┼──────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────┐
│         NeMo Guardrails Server               │  :8000 (internal)
│                                              │
│  self_check_input rail (active)              │
│  ─────────────────────────────               │──► Ollama + Llama 3.2 3B (local judge)
│  Output rails (deferred — v2)                │    evaluation stays on-network
│  Colang flows (reference only)               │
└──────────────────────────────────────────────┘
                   │ (only policy-compliant requests)
                   ▼
         Cloud LLM (OpenAI gpt-4o-mini / gpt-4o)
```

**Key invariants:** Secrets and PII are scrubbed before any cloud call. Layer 1 is fully deterministic and cannot be bypassed. The local judge ensures that sensitive queries are evaluated on-network — they never reach the internet as part of the act of deciding whether to block them.

---

## Tenant Policies

| Tenant | Model | Budget | Topic Control | PII | Jailbreak |
|--------|-------|--------|---------------|-----|-----------|
| Marketing | gpt-4o-mini | $200/mo hard | Block-list (roadmap, financials, employees) | Strip silently | Semantic check |
| Engineering | gpt-4o | $2000/mo soft | None (ADR-005) | Warn + allow | Semantic check (lenient prompt) |
| Support | gpt-4o-mini | $500/mo hard | Allow-list (product only) | Block hard | Full semantic |

---

## Configuration Guide

### Adding a tenant

1. Add a team via LiteLLM API or extend `scripts/setup-tenants.sh`
2. Create a NeMo config in `guardrails/<tenant-name>/` (copy from `guardrails/engineering/` as a starting point)
3. Map the `team_alias` to a `config_id` in `custom_guardrails/nemo_bridge.py`

### Changing topic policy

Topic control is driven by the `self_check_input` prompt in `guardrails/<tenant>/prompts.yml`.

- **Block-list (Marketing):** Edit the BLOCK section in `prompts.yml`, restart NeMo
- **Allow-list (Support):** Edit the ALLOW section in `prompts.yml`, restart NeMo

> **Note on Colang flows:** The `.co` files under `guardrails/<tenant>/` are reference documentation. In NeMo server mode, Colang flows behave as chatbot-turn flows, not semantic evaluators — so the active policy logic lives in `prompts.yml`, not `.co` files. See [ADR-004](docs/decisions/004-nemo-guardrails-dsl.md).

### Adjusting budgets

```bash
# Via LiteLLM API (requires master key)
curl -X POST http://localhost:8080/team/update \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<id>", "max_budget": 500}'
```

### Upgrading the judge model

The current judge is **Ollama + Llama 3.2 3B** (local, zero marginal cost). Config in all `guardrails/*/config.yml`:

```yaml
- type: self_check_input
  engine: openai
  model: llama3.2:3b
  parameters:
    base_url: "http://ollama:11434/v1"
```

To switch to a cloud judge (higher accuracy, adds API cost), replace with:
```yaml
- type: self_check_input
  engine: openai
  model: gpt-4o-mini
```

Then restart NeMo: `docker compose restart nemo`

See [ADR-003](docs/decisions/003-local-judge-ollama.md) for benchmark results and trade-offs.

---

## File Structure

```
.
├── docker-compose.yml          # Orchestrates 4 services
├── Dockerfile.nemo             # Custom NeMo image (no official image exists)
├── litellm-config.yaml         # Gateway config: models, guardrails, routing
│
├── custom_guardrails/          # Python hooks loaded by LiteLLM
│   ├── secrets_detector.py     # Layer 1: regex secrets scanning
│   ├── nemo_bridge.py          # Layer 2: NeMo integration bridge
│   └── pii_detector.py         # Layer 1: per-tenant PII handling
│
├── secrets/
│   └── patterns.yaml           # Regex patterns for secrets detection
│
├── guardrails/                 # NeMo Guardrails configs (Colang 1.0)
│   ├── marketing/              # Block-list: roadmap, financials
│   ├── engineering/            # Minimal: jailbreak only
│   └── support/                # Allow-list + KB (fact-checking wired in v2)
│       └── kb/                 # Product knowledge base (ready, not yet active)
│
├── scripts/
│   ├── init-ollama.sh          # Pull llama3.2:3b on first boot
│   └── setup-tenants.sh        # Create teams + virtual keys via API
│
├── tests/
│   ├── run-all.sh              # Run all tests, produce summary report
│   ├── 00-health-check.sh
│   ├── 01-secrets-detection.sh
│   ├── 02-marketing-topic-block.sh
│   ├── 03-engineering-unrestricted.sh
│   ├── 04-support-topic-allow.sh
│   ├── 05-support-factcheck.sh
│   ├── 06-pii-handling.sh
│   ├── 07-budget-enforcement.sh
│   ├── 08-jailbreak-detection.sh
│   └── 09-fail-open.sh         # Run with RUN_FAILOPEN=true
│
├── docs/
│   ├── decisions/              # 11 Architecture Decision Records
│   ├── trade-off-matrix.md
│   ├── scope-boundaries.md
│   └── observability-design.md
│
└── schemas/
    └── tenant-config.schema.yaml
```

---

## Troubleshooting

### LiteLLM health shows "unhealthy endpoints"

Check that `OPENAI_API_KEY` is set in `.env` and restart:
```bash
docker compose restart litellm
```

### NeMo is not blocking topics

NeMo uses `self_check_input` with a local Ollama judge (Llama 3.2 3B). Requests can take 5–30 seconds on CPU — this is normal. Check NeMo logs:
```bash
docker compose logs nemo --follow
```

Verify the model is loaded:
```bash
docker exec -it llm-control-plane-ollama-1 ollama list
```

### "MARKETING_KEY not set" when running tests

Run `bash scripts/setup-tenants.sh` first. It creates `.env.tenants`.

### Fail-open test

Run explicitly: `RUN_FAILOPEN=true bash tests/run-all.sh`
This stops and starts the NeMo container — takes ~30 seconds.

---

## Design Decisions

See `docs/decisions/` for 11 ADRs covering every significant design choice.
Key decisions: [ADR-001](docs/decisions/001-litellm-over-custom.md) (why LiteLLM), [ADR-003](docs/decisions/003-local-judge-ollama.md) (why local judge), [ADR-011](docs/decisions/011-fail-open.md) (fail-open policy).

---

## What This Is Not

- A production-hardened deployment (no TLS, no auth federation, single-region)
- A replacement for a dedicated data loss prevention (DLP) tool
- A compliance certification (SOC2, HIPAA require additional controls)

See `docs/scope-boundaries.md` for the full list of out-of-scope items.
