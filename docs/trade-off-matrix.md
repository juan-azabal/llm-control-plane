# Trade-off Matrix

This document makes the key design tensions explicit. Every meaningful design decision involves accepting a cost to get a benefit.

---

## Security vs Availability

| Decision | Security Benefit | Availability Cost |
|----------|-----------------|-------------------|
| Fail-open (ADR-011) | Deterministic rails always active | Semantic rails bypass during outage |
| Local judge target (ADR-003) | No content sent externally for evaluation | Judge model quality limited by local compute |
| MVP: gpt-4o-mini as judge | Higher judgment accuracy during validation | Content sent to OpenAI for judge evaluation |
| Hard budget caps | Prevents runaway spend | Blocks users mid-session when cap hit |
| Secrets detection before NeMo | High-severity secrets never seen by NeMo | Extra latency for every request |

**The dominant tradeoff:** This system is designed to enable AI adoption, not to prevent it. Every "fail-open" and "warn-and-allow" decision reflects a deliberate bet that visible-but-imperfect control is better than invisible circumvention.

---

## Model Quality vs Cost

| Component | MVP (Current) | Target (v1) | Higher Quality (v2+) | Cost of Upgrade |
|-----------|--------------|------------|----------------------|-----------------|
| Judge model | gpt-4o-mini (cloud, per-token) | Llama 3.2 3B via Ollama (free, local) | Llama 3.1 8B/70B or fine-tuned classifier | GPU hardware or cloud API |
| Fact-checking | Not active (deferred) | self_check_facts + gpt-4o-mini | RAG with vector DB + capable model | Vector DB infra + latency |
| Output safety | Not active (deferred) | self_check_output + gpt-4o-mini | Fine-tuned output classifier | Labeled training data |
| Jailbreak detection | self_check_input + gpt-4o-mini | self_check_input + Ollama 3B | Llama Guard (purpose-built) | ~Same cost, different model |
| Semantic topic detection | LLM classification + gpt-4o-mini | LLM classification + Ollama 3B | Fine-tuned BERT classifier | Training data + fine-tuning pipeline |

**Immediate next step:** Switch the judge from gpt-4o-mini to Ollama 3B. The prompts are validated and working with gpt-4o-mini — the same prompts should work with 3B after minor tuning. This eliminates the double cloud API cost per request.

---

## Precision vs Recall

For each security rail, there's a tunable tradeoff between false positives (blocking legitimate queries) and false negatives (letting harmful queries through).

| Rail | Current Bias | Effect |
|------|-------------|--------|
| Secrets detection | High precision (regex is specific) | Few false positives; novel secret formats missed |
| Topic control (marketing block-list) | Balanced | Borderline queries may go either way |
| Topic control (support allow-list) | Leans toward recall | May block some legitimate phrasings |
| Jailbreak detection | Leans toward precision for engineering | More false negatives to avoid blocking devs |
| PII detection | High recall for known patterns | May strip non-PII that matches patterns |

**Monitoring signal:** Track user complaints about blocked requests (precision failures) and audit logs for concerning content that passed through (recall failures). Tune thresholds based on actual incident rates.

---

## Build vs Buy

| Function | Current Approach | SaaS Alternative |
|----------|-----------------|-----------------|
| API Gateway | LiteLLM (open source) | Portkey, Helicone, OpenRouter |
| Semantic rails | NeMo Guardrails (open source) | Guardrails.ai, Robust Intelligence |
| Local inference | Ollama (open source) | Any GPU cloud provider |
| PII detection | Custom regex | Google Cloud DLP, AWS Comprehend |
| Secrets scanning | Custom regex | GitLeaks, Trufflehog (request-time) |
| Budget control | LiteLLM built-in | Cloud provider cost controls |

The "build" choices prioritize: full control over data, no vendor lock-in, zero per-request SaaS costs. The tradeoff is maintenance burden and lower out-of-box quality.

---

## Latency Budget

For a typical request through the full stack:

| Stage | MVP Latency (gpt-4o-mini judge) | Target Latency (Ollama 3B, CPU) | Target Latency (Ollama 8B, GPU) |
|-------|--------------------------------|--------------------------------|--------------------------------|
| LiteLLM routing | ~5ms | ~5ms | ~5ms |
| Secrets detection | ~2ms | ~2ms | ~2ms |
| PII detection | ~2ms | ~2ms | ~2ms |
| NeMo pre-call hook | 500ms–2s | 1–10s | <1s |
| Cloud LLM (gpt-4o-mini) | 500ms–3s | 500ms–3s | 500ms–3s |
| NeMo post-call hook (output rails — deferred) | N/A | 1–10s | <1s |
| **Total (MVP, no output rails)** | **~1–5 seconds** | — | — |
| **Total (target, CPU, with output rails)** | — | **~5–25 seconds** | — |
| **Total (target, GPU, with output rails)** | — | — | **~2–4 seconds** |

**MVP note:** No output rails active → post-call hook is a no-op. Total latency is dominated by the cloud LLM call (~1–3s) plus the gpt-4o-mini judge (~1–2s).

**P99 latency on CPU with Ollama is not acceptable for customer-facing apps.** This system is designed for internal employee tooling. For customer-facing latency requirements, GPU acceleration is mandatory.
