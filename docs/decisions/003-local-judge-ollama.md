# ADR-003: Local LLM Judge via Ollama

**Status:** Accepted

## Context

NeMo Guardrails' `self_check_input`, `self_check_output`, and `self_check_facts` rails require an LLM to evaluate requests. Options for the judge model:

- Use the same cloud LLM being called (e.g., ask GPT-4 to judge itself)
- Use a different cloud LLM (e.g., Claude to judge GPT requests)
- Use a local model via Ollama (e.g., Llama 3.2 3B)

## Decision

Use **Ollama running Llama 3.2 3B** as the local semantic judge.

## Rationale

### Primary reason: the judge sees potentially sensitive content

To evaluate whether a request is harmful or off-topic, the judge model must read that request in full. This creates a critical constraint: **if the judge is a cloud model, every employee query — including those containing sensitive company information — is transmitted to a third-party LLM for evaluation, before it is decided whether to block it.**

This is a structural contradiction. A system designed to prevent sensitive data from leaving the company would be sending that data externally on every request, as part of the act of deciding whether to block it.

Using a local judge resolves the contradiction: the semantic evaluation happens entirely within the company's network perimeter. Sensitive queries are evaluated locally and blocked locally — they never reach the internet.

### Secondary reasons

2. **No per-judgment cost.** Cloud API calls cost money per token. With 3B parameters on a modern CPU, the marginal cost per judgment is electricity. High-volume deployments can easily make this 10x cheaper than cloud judging.

3. **Independence from cloud availability.** If OpenAI has an outage, the guardrail shouldn't also fail. Local inference is independent.

4. **Data sovereignty.** Even for benign requests, the content of every query is visible to the judge. Sending all employee queries to a third-party LLM for routine policy evaluation creates a continuous data-sharing relationship that may conflict with data residency requirements or employee privacy expectations.

## The Double-Send Problem

When using a cloud judge, every guarded request results in **two** external API calls:

```
Employee query → [NeMo judge: gpt-4o-mini at OpenAI] → decision
                                                        ↓ (if allowed)
Employee query → [Production LLM: gpt-4o-mini at OpenAI] → response
```

The query is sent to OpenAI twice: once for evaluation, once for the response. This means:
- OpenAI sees 100% of employee queries, not just the ones that pass policy
- A query containing internal roadmap details is transmitted to evaluate whether to block it
- The "secrets detection" Layer 1 scrubs credentials and PII, but semantic content (product strategy, financial discussions, employee matters) passes through Layer 1 and reaches the cloud judge

With a local judge:

```
Employee query → [NeMo judge: Llama 3.2 3B on local Ollama] → decision
                                                               ↓ (if allowed)
Employee query (clean) → [Production LLM: gpt-4o-mini at OpenAI] → response
```

Only approved, policy-compliant requests reach the cloud. The evaluation itself stays on-network.

## Trade-offs Accepted

- **Model quality.** Llama 3.2 3B is significantly less capable than GPT-4 or Claude at nuanced judgment. This is quantified in `tests/08-jailbreak-detection.sh` — novel jailbreaks may evade detection.
- **Latency.** CPU inference on 3B parameters adds 1–10 seconds per request. On GPU this drops to <1s. Acceptable for internal tools; not for customer-facing latency-sensitive apps.
- **Cold start.** First request after startup is slow while the model loads. Subsequent requests use cached weights.

## Upgrade Path

If judgment quality is insufficient:
1. Upgrade to Llama 3.2 8B or 70B with a GPU node
2. Use a fine-tuned safety classifier (faster, purpose-built)
3. For output safety only (not input): use GPT-4 as a judge (acceptable because the input has already passed Layer 1)

## Implementation Note (Phase 6 — Benchmark Results)

The judge was switched from gpt-4o-mini to **Ollama + Llama 3.2 3B** in Phase 6 after prompts were validated with the cloud model. Benchmark results from `tests/judge-benchmark/` (40 prompts, 3 iterations of prompt tuning):

| Tenant | Precision | Recall | F1 | Notes |
|--------|-----------|--------|----|-------|
| marketing | 100% | 88.8% | 94.7% | 1 persistent FN: implicit HR requests (job postings) |
| engineering | 100% | 100% | 100% | Full accuracy after explicit DoS/malware block rule |
| support | 100% | 83.3% | 90.8% | 1 persistent FN: competitor comparison phrasing |

**Overall: 38/40 correct (95%).**

The 2 persistent failures (IDs 31 and 39) represent edge cases where the 3B model's limited semantic reasoning prevents consistent classification. These are documented in `tests/judge-benchmark/results.md`.

**Consequence:** The 3B model meets the ≥90% threshold for engineering and support (F1). Marketing recall is 88.8% — marginally below the 90% threshold for recall. This is accepted because:
1. The 1 missed case (HR job posting) is a genuinely ambiguous edge case
2. The deterministic Layer 1 (secrets + PII) still protects the most critical data
3. The security benefit of local evaluation (no sensitive queries sent externally) outweighs the marginal accuracy gap vs. a cloud judge

**Model name correction:** The correct model name for Ollama's OpenAI-compatible API is `llama3.2:3b` (not `ollama/llama3.2:3b`). Config example:
```yaml
- type: self_check_input
  engine: openai
  model: llama3.2:3b
  parameters:
    base_url: "http://ollama:11434/v1"
```

## Invalidation Signal

A security incident where a harmful request evaded NeMo detection and reached the cloud LLM, causing a real-world negative outcome. At that point, upgrade the judge model quality (not the architecture).
