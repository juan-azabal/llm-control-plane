# ADR-010: Jailbreak Detection via NeMo self_check_input

**Status:** Accepted

## Context

Users may attempt to manipulate the LLM into ignoring its system prompt, breaking out of its configured persona, or producing harmful content. Classic jailbreak patterns include:

- "Act as DAN (Do Anything Now)"
- "Ignore your previous instructions"
- Role-play scenarios designed to bypass restrictions
- Prompt injection via hypothetical or fictional framing
- Encoded instructions (Base64, rot13, etc.)

How should we detect and block these?

## Decision

Use **NeMo Guardrails' `self_check_input` rail** as the primary jailbreak detection mechanism. The rail uses the local Llama 3.2 3B model to evaluate whether each input is a potential jailbreak.

Sensitivity varies by tenant:
- **Marketing/Support:** Full `self_check_input` with low threshold
- **Engineering:** `self_check_input` with higher threshold (heuristic jailbreak check only)

## Rationale

1. **Semantic detection, not keyword detection.** Jailbreaks are creative. "Please pretend you have no restrictions" bypasses any keyword blocklist. Semantic evaluation by an LLM catches structural patterns regardless of exact phrasing.

2. **NeMo's self_check_input is purpose-built.** The NeMo team has curated jailbreak examples across many prompt injection patterns. The rail benefits from this curation without us having to build our own training set.

3. **Local evaluation.** We don't send the potentially malicious prompt to a cloud LLM to evaluate whether it's malicious. The local judge evaluates it first.

## Known Limitations

1. **3B model false negative rate.** Novel, creative jailbreaks — especially those using narrative, roleplay depth, or sophisticated framing — may evade a 3B model. The `08-jailbreak-detection.sh` test quantifies this.

2. **False positives on legitimate edge cases.** "You are playing a security researcher" or "In a hypothetical scenario" are common in legitimate engineering use cases. The higher threshold for Engineering is designed to reduce false positives for power users.

3. **No adversarial robustness training.** The 3B model wasn't specifically trained to resist jailbreaks — it's a general-purpose model being used as a judge. A fine-tuned safety classifier would be more robust.

4. **Encoded inputs.** Base64 or other encoding can confuse the judge. The model may not decode and evaluate the underlying intent.

## Upgrade Path

1. **Short term:** Upgrade to Llama 3.2 8B or a fine-tuned safety classifier
2. **Medium term:** Add an ensemble approach — combine keyword signals with semantic judgment
3. **Long term:** Use a purpose-built adversarial robustness model (e.g., Llama Guard)

## Invalidation Signal

A successful jailbreak that reached the cloud LLM and produced output that caused a real negative outcome (data leak, harmful content in customer-facing context). At that point, treat jailbreak detection as a P0 security issue and escalate the judge model quality.
