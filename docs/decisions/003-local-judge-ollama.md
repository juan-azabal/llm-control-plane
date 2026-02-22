# ADR-003: Local LLM Judge via Ollama

**Status:** Accepted — MVP exception in effect (see Implementation Note)

## Context

NeMo Guardrails' `self_check_input`, `self_check_output`, and `self_check_facts` rails require an LLM to evaluate requests. Options for the judge model:

- Use the same cloud LLM being called (e.g., ask GPT-4 to judge itself)
- Use a different cloud LLM (e.g., Claude to judge GPT requests)
- Use a local model via Ollama (e.g., Llama 3.2 3B)

## Decision

Use **Ollama running Llama 3.2 3B** as the local semantic judge.

## Rationale

1. **Zero data exfiltration.** A flagged request that contains sensitive content must not be sent to a cloud LLM to be evaluated. If the judge is cloud-based, you've already sent the potentially harmful content externally. A local judge keeps all content on-network.

2. **No per-judgment cost.** Cloud API calls cost money per token. With 3B parameters on a modern CPU, the marginal cost per judgment is electricity. High-volume deployments can easily make this 10x cheaper than cloud judging.

3. **Independence from cloud availability.** If OpenAI has an outage, the guardrail shouldn't also fail. Local inference is independent.

4. **Privacy by default.** Even for benign requests, the content of every request is visible to the judge. We should not send all employee queries to a third-party LLM just for policy evaluation.

## Trade-offs Accepted

- **Model quality.** Llama 3.2 3B is significantly less capable than GPT-4 or Claude at nuanced judgment. This is quantified in `tests/08-jailbreak-detection.sh` — novel jailbreaks may evade detection.
- **Latency.** CPU inference on 3B parameters adds 1–10 seconds per request. On GPU this drops to <1s. Acceptable for internal tools; not for customer-facing latency-sensitive apps.
- **Cold start.** First request after startup is slow while the model loads. Subsequent requests use cached weights.

## Upgrade Path

If judgment quality is insufficient:
1. Upgrade to Llama 3.2 8B or 70B with a GPU node
2. Use a fine-tuned safety classifier (faster, purpose-built)
3. For output safety only (not input): use GPT-4 as a judge (acceptable because the input has already passed Layer 1)

## Implementation Note (MVP)

The MVP uses **gpt-4o-mini** (OpenAI) as the NeMo judge model instead of Ollama + Llama 3.2 3B. This was a deliberate pragmatic choice during the MVP phase:

- **Reason:** gpt-4o-mini produces more reliable Yes/No judgments for `self_check_input`, allowing the full control plane stack to be validated without prompt-tuning the 3B model first.
- **Cost implication:** Each guarded request now calls gpt-4o-mini twice (once as the judge, once as the task LLM). This is not acceptable for production.
- **Ollama readiness:** Ollama + Llama 3.2 3B is pre-pulled (`scripts/init-ollama.sh`). Switching is a one-line change in each `guardrails/*/config.yml` (change `engine: openai / model: gpt-4o-mini` to `engine: openai / model: ollama/llama3.2:3b` with `base_url: http://ollama:11434/v1`).
- **This ADR's decision stands.** The target architecture uses a local judge. The MVP is the exception, not the rule.

## Invalidation Signal

A security incident where a harmful request evaded NeMo detection and reached the cloud LLM, causing a real-world negative outcome. At that point, upgrade the judge model quality (not the architecture).
