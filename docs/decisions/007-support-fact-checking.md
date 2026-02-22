# ADR-007: Fact-Checking for Support Tenant

**Status:** Accepted

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

## Invalidation Signal

If the fact-checker's false positive rate exceeds 20% (flags accurate responses as hallucinations), the KB is likely stale or the 3B model is insufficient for this task. Either update the KB or upgrade the judge model.
