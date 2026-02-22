# ADR-004: NeMo Guardrails as the Semantic Rail Engine

**Status:** Accepted

## Context

We need a way to express semantic policies ("block questions about unreleased product features") that keyword filtering cannot handle. Options:

- Keyword/regex blocking (simple but easily bypassed)
- Custom prompt-based classifier (build from scratch)
- NeMo Guardrails (Colang DSL + NVIDIA-maintained rail library)
- Guardrails.ai (different project, output validation focused)

## Decision

Use **NeMo Guardrails with Colang 1.0** as the semantic policy engine.

## Rationale

1. **Declarative policy DSL.** Colang lets policy authors express rules in near-natural-language without writing Python. This separates policy from code — product, legal, or compliance teams can read and modify policies.

2. **Semantic understanding, not keywords.** `"When does v3 launch?"` contains no blocked keyword, but NeMo's LLM-based input rail understands it's asking about internal roadmap. Keyword blocking would miss this.

3. **Self-check library.** NeMo provides pre-built rails for jailbreak detection (`self_check_input`), output safety (`self_check_output`), and factual grounding (`self_check_facts`). These are based on published research and well-tested.

4. **HTTP server mode.** NeMo runs as a standalone server with an OpenAI-compatible API. This means our bridge code is thin — just HTTP calls.

## Why Colang 1.0 (not 2.0)

Colang 2.0 is a more powerful but less documented and more complex language. The full Guardrails Library (`self_check_input`, etc.) is only mature in Colang 1.0. For this project's needs, 1.0 is sufficient.

## Trade-offs Accepted

- **No official Docker image.** NeMo Guardrails has no maintained Docker image. We build our own from `python:3.11-slim`. This means we own the maintenance of that image.
- **Hallucinated examples.** NeMo's `self_check_input` uses the LLM to evaluate whether something matches the example utterances. With a 3B model, there will be false positives and negatives.
- **Colang 1.0 is in maintenance mode.** The NeMo team is moving toward Colang 2.0. Eventually, 1.0 will need migration.

## Invalidation Signal

If NeMo Guardrails deprecates the HTTP server mode or drops Colang 1.0 support without a migration path, evaluate replacing with a custom classifier endpoint backed by a fine-tuned model.
