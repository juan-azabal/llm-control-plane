# LLM Control Plane

An enterprise AI governance layer that routes, guards, and governs LLM usage across business teams — each with different risk profiles, budgets, and content policies.

**Stack:** LiteLLM (gateway) · NeMo Guardrails (semantic rails) · Ollama + Llama 3.2 3B (local judge) · Docker Compose

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
# Pull the local judge model (~2GB, one-time)
bash scripts/init-ollama.sh

# Create tenant teams + virtual keys
bash scripts/setup-tenants.sh
```

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
│  │ (regex)      │  │ (strip/warn/block)      │ │
│  └──────────────┘  └─────────────────────────┘ │
│  ┌──────────────┐                               │
│  │ Budget Guard │  (LiteLLM built-in)           │
│  └──────────────┘                               │
│                                                 │
│  Layer 2 — Semantic Rails (per-tenant policy)  │
│  ┌─────────────────────────────────────────┐   │
│  │       NeMo Guardrails Bridge            │   │
│  │  marketing: block-list topics           │   │
│  │  engineering: jailbreak only            │   │
│  │  support: allow-list + fact-check       │   │
│  └───────────────┬─────────────────────────┘   │
│                  │ HTTP                          │
└──────────────────┼──────────────────────────────┘
                   ▼
┌──────────────────────────────┐
│      NeMo Guardrails         │  :8000 (internal)
│  ┌────────────┐              │
│  │  Colang    │              │
│  │  flows     │ ────────────►│──► Ollama (3B judge)
│  └────────────┘              │    :11434 (internal)
└──────────────────────────────┘
                   │ (only clean requests)
                   ▼
         Cloud LLM (OpenAI gpt-4o-mini / gpt-4o)
```

**Key invariant:** Sensitive data never reaches the cloud. Layer 1 and 2 both run fully local.

---

## Tenant Policies

| Tenant | Model | Budget | Topic Control | PII | Jailbreak |
|--------|-------|--------|---------------|-----|-----------|
| Marketing | gpt-4o-mini | $200/mo hard | Block-list (roadmap, financials, employees) | Strip silently | Semantic check |
| Engineering | gpt-4o | $2000/mo soft | None (ADR-005) | Warn + allow | Heuristic only |
| Support | gpt-4o-mini | $500/mo hard | Allow-list (product only) | Block hard | Full semantic |

---

## Configuration Guide

### Adding a tenant

1. Add a team via LiteLLM API or extend `scripts/setup-tenants.sh`
2. Create a NeMo config in `guardrails/<tenant-name>/` (copy from `guardrails/engineering/` as a starting point)
3. Map the `team_alias` to a `config_id` in `custom_guardrails/nemo_bridge.py`

### Changing topic policy

Topic control is in Colang files under `guardrails/<tenant>/`:
- Block-list: define blocked topic flows in `config.co`, restart NeMo
- Allow-list: define allowed topic flows with `bot inform off topic` for others

### Adjusting budgets

```bash
# Via LiteLLM API (requires master key)
curl -X POST http://localhost:8080/team/update \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<id>", "max_budget": 500}'
```

### Upgrading the judge model

Edit `guardrails/*/config.yml`, change `model: ollama/llama3.2:3b` to `ollama/llama3.1:8b`, then pull the model and restart NeMo.

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
│   └── support/                # Allow-list + fact-checking + KB
│       └── kb/                 # Product knowledge base for fact-checking
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

NeMo uses a local LLM (Llama 3.2 3B) as a semantic judge. It can take 5–30 seconds per request. Check NeMo logs:
```bash
docker compose logs nemo --follow
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
