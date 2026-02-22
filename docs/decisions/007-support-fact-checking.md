# ADR-007: Fact-Checking for Support Tenant

**Status:** Accepted — Implementation deferred to v2 (see Implementation Note)

## Context

The Support tenant's LLM might hallucinate product capabilities (e.g., claim we have a mobile app when we don't, claim an integration exists that doesn't). Support agents acting on hallucinated product claims create real customer expectations that sales and engineering must then manage.

Should we implement fact-checking for support responses, and if so, how?

## Decision

Enable NeMo's `self_check_facts` output rail for the Support tenant. Maintain a product knowledge base in `guardrails/support/kb/` that the fact-checker references.

## Rationale

1. **Support hallucinations have direct business impact.** Unlike marketing where hallucinations might be caught before publication, support conversations happen in real-time with customers. A support agent saying "yes, we have a Salesforce integration" based on a hallucinated LLM response creates an immediate expectation.

2. **The knowledge base scope is manageable.** Support queries are narrow. The knowledge base covers features, pricing, troubleshooting, and account management — four documents, easily maintained.

3. **NeMo's fact-checking is additive, not blocking by default.** `self_check_facts` compares the response against retrieved context and either passes it through or flags it. It's not a hard block — it's a correction layer.

## Trade-offs Accepted

- **3B model fact-checking accuracy.** A 3B model comparing a response against a knowledge base will miss subtle inconsistencies and may also flag accurate responses. The accuracy degrades with complex multi-fact responses.
- **Knowledge base maintenance burden.** When the product changes, the KB must be updated. A stale KB is worse than no KB (the fact-checker will incorrectly flag accurate new features as hallucinations).
- **Latency.** Fact-checking requires an additional LLM inference pass for every output. This adds 1–5 seconds.

## Alternative Considered

Use a retrieval-augmented generation (RAG) system that injects KB context into the system prompt, making hallucination less likely in the first place. This is more complex to implement but reduces reliance on the probabilistic fact-checking step. Deferred to v2.

## Implementation Note (MVP)

`self_check_facts` is **not active in the MVP**. The decision to implement it stands, but implementation is deferred to v2 due to complexity and the risk of false positives blocking legitimate support responses before the system is validated.

**Current MVP state:**
- Product knowledge base exists at `guardrails/support/kb/` (features.md, pricing.md, troubleshooting.md, account.md)
- `self_check_facts` is NOT configured in `guardrails/support/config.yml`
- `nemo_bridge.py` has a `async_post_call_success_hook` that calls NeMo for output rails, but output rails are not enabled
- `tests/05-support-factcheck.sh` runs but hallucination detection failures are non-fatal

**v2 implementation path:**
1. Add `self_check_facts` model to `guardrails/support/config.yml`
2. Add `self_check_facts` to `rails.output.flows`
3. Add `self_check_facts` prompt to `guardrails/support/prompts.yml` referencing the KB
4. Enable output rails in `nemo_bridge.py` post_call hook
5. Re-run `tests/05-support-factcheck.sh` and make failures fatal

## Invalidation Signal

If the fact-checker's false positive rate exceeds 20% (flags accurate responses as hallucinations), the KB is likely stale or the 3B model is insufficient for this task. Either update the KB or upgrade the judge model.
