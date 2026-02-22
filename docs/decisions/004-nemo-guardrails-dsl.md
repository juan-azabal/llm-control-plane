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

1. **Declarative policy DSL.** Colang lets policy authors express rules in near-natural-language without writing Python. This separates policy from code — product, legal, or compliance teams can read and modify policies. *Note: in the MVP, the active policy lives in `prompts.yml` (natural-language prompts for `self_check_input`), not in Colang flows. Colang `.co` files serve as human-readable policy documentation. The intent of readable, non-Python policy definition is still achieved; the mechanism is prompts rather than Colang DSL.*

2. **Semantic understanding, not keywords.** `"When does v3 launch?"` contains no blocked keyword, but NeMo's LLM-based input rail understands it's asking about internal roadmap. Keyword blocking would miss this.

3. **Self-check library.** NeMo provides pre-built rails for jailbreak detection (`self_check_input`), output safety (`self_check_output`), and factual grounding (`self_check_facts`). These are based on published research and well-tested.

4. **HTTP server mode.** NeMo runs as a standalone server with an OpenAI-compatible API. This means our bridge code is thin — just HTTP calls.

## Why Colang 1.0 (not 2.0)

Colang 2.0 is a more powerful but less documented and more complex language. The full Guardrails Library (`self_check_input`, etc.) is only mature in Colang 1.0. For this project's needs, 1.0 is sufficient.

## Trade-offs Accepted

- **No official Docker image.** NeMo Guardrails has no maintained Docker image. We build our own from `python:3.11-slim`. This means we own the maintenance of that image.
- **Hallucinated examples.** NeMo's `self_check_input` uses the LLM to evaluate whether something matches the example utterances. With a 3B model, there will be false positives and negatives.
- **Colang 1.0 is in maintenance mode.** The NeMo team is moving toward Colang 2.0. Eventually, 1.0 will need migration.
- **Colang flows do NOT work as semantic evaluators in server mode.** This is a significant finding from MVP implementation: Colang `define flow` blocks are chatbot-turn conversation flows (they match on intent patterns and drive dialogue state). When used as `rails.input.flows`, they execute as conversation turns but do not function as LLM-evaluated topic classifiers. The `self_check_input` built-in rail (backed by an LLM judge and a custom prompt) is the correct mechanism for semantic input evaluation. The `.co` files in this project document the intended policy in a readable format but are not active guardrails in the MVP.

## Implementation Note (MVP)

The active semantic evaluation mechanism is `self_check_input` configured in each tenant's `config.yml`, powered by a custom prompt in `prompts.yml`. Colang flows (`.co` files) are kept as reference documentation and are ready to activate if NeMo adds evaluator-mode flow execution in a future version.

## Invalidation Signal

If NeMo Guardrails deprecates the HTTP server mode or drops Colang 1.0 support without a migration path, evaluate replacing with a custom classifier endpoint backed by a fine-tuned model.
