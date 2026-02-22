# Trade-off Matrix

This document makes the key design tensions explicit. Every meaningful design decision involves accepting a cost to get a benefit.

---

## Security vs Availability

| Decision | Security Benefit | Availability Cost |
|----------|-----------------|-------------------|
| Local judge via Ollama (ADR-003) | Sensitive queries evaluated on-network — never sent to a third party to decide whether to block them | Judge model quality limited by local compute; CPU latency 5–30s |
| Fail-open (ADR-011) | Deterministic rails always active | Semantic rails bypass during outage |
| Hard budget caps | Prevents runaway spend | Blocks users mid-session when cap hit |
| Secrets detection before NeMo | High-severity secrets never seen by NeMo or the judge | Extra latency for every request |

**The judge locality problem:** A cloud-based judge creates a structural contradiction — to decide whether to block a sensitive query, the system must first transmit that query externally. The local judge resolves this: evaluation happens on-network, and only policy-compliant requests reach the cloud LLM. See ADR-003 for the full argument.

**The dominant tradeoff:** This system is designed to enable AI adoption, not to prevent it. Every "fail-open" and "warn-and-allow" decision reflects a deliberate bet that visible-but-imperfect control is better than invisible circumvention.

---

## Judge Model Quality vs Security Boundary

The judge model choice is primarily a security decision, not a cost decision. A cloud judge sees 100% of employee queries — including sensitive ones — before deciding whether to block them. A local judge evaluates on-network.

| Component | Current (v1) | Higher Quality (v2+) | Upgrade Cost |
|-----------|-------------|----------------------|--------------|
| Judge model | Llama 3.2 3B via Ollama (local, F1: 95% overall) | Llama 3.1 8B/70B or fine-tuned classifier (local) | GPU hardware |
| Fact-checking | Not active (deferred) | self_check_facts + local model + RAG | Vector DB infra + latency |
| Output safety | Not active (deferred) | self_check_output + local model | Wiring + latency |
| Jailbreak detection | self_check_input + Ollama 3B | Llama Guard (purpose-built safety classifier) | ~Same infra, different model |
| Semantic topic detection | LLM classification + Ollama 3B | Fine-tuned BERT classifier | Training data + fine-tuning pipeline |

**Why not use a cloud judge for higher accuracy?** Upgrading accuracy by switching to a cloud judge (e.g., gpt-4o-mini) would mean sending every employee query to OpenAI for evaluation — including the sensitive ones we're trying to protect. The marginal accuracy gain does not justify breaking the network boundary. If higher accuracy is required, upgrade the local model (8B, 70B, or a fine-tuned classifier), not the judge location.

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
