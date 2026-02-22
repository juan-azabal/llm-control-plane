# Trade-off Matrix

This document makes the key design tensions explicit. Every meaningful design decision involves accepting a cost to get a benefit.

---

## Security vs Availability

| Decision | Security Benefit | Availability Cost |
|----------|-----------------|-------------------|
| Fail-open (ADR-011) | Deterministic rails always active | Semantic rails bypass during outage |
| Local judge (ADR-003) | No content sent externally for evaluation | Judge model quality limited by local compute |
| Hard budget caps | Prevents runaway spend | Blocks users mid-session when cap hit |
| Secrets detection before NeMo | High-severity secrets never seen by NeMo | Extra latency for every request |

**The dominant tradeoff:** This system is designed to enable AI adoption, not to prevent it. Every "fail-open" and "warn-and-allow" decision reflects a deliberate bet that visible-but-imperfect control is better than invisible circumvention.

---

## Model Quality vs Cost

| Component | Current | Higher Quality | Cost of Upgrade |
|-----------|---------|----------------|-----------------|
| Judge model | Llama 3.2 3B (free, local) | Llama 3.1 70B or fine-tuned classifier | GPU hardware ($) or cloud API ($$$) |
| Fact-checking | self_check_facts + 3B | RAG with vector DB + 70B judge | Vector DB infra + latency |
| Jailbreak detection | self_check_input + 3B | Llama Guard (purpose-built) | ~Same cost, different model |
| Semantic topic detection | LLM classification + 3B | Fine-tuned BERT classifier | Training data + fine-tuning pipeline |

**Recommendation:** Upgrade the judge to 8B or 13B before upgrading further. The quality jump from 3B to 8B is significant; from 8B to 70B is meaningful but more expensive. Benchmark first.

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

| Stage | Typical Latency | Notes |
|-------|----------------|-------|
| LiteLLM routing | ~5ms | In-memory |
| Secrets detection | ~2ms | Regex, CPU |
| PII detection | ~2ms | Regex, CPU |
| NeMo pre-call hook | 100ms–5s | LLM inference, CPU-bound |
| Cloud LLM (gpt-4o-mini) | 500ms–3s | Network + model |
| NeMo post-call hook | 100ms–5s | LLM inference, CPU-bound |
| **Total (worst case)** | **~15 seconds** | CPU inference on 3B |
| **Total (GPU-accelerated)** | **~2–3 seconds** | Acceptable for internal tools |

**P99 latency on CPU is not acceptable for customer-facing apps.** This system is designed for internal employee tooling where 5–10s response times are tolerable. For customer-facing latency requirements, GPU acceleration is mandatory.
