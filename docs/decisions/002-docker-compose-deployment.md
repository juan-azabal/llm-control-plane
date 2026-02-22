# ADR-002: Docker Compose for Orchestration

**Status:** Accepted

## Context

The system has four services that must communicate: LiteLLM, NeMo Guardrails, Ollama, and Postgres. We need a way to run them together with shared networking. Options:

- Docker Compose (single-node)
- Kubernetes (multi-node)
- Bare metal / systemd services
- Docker Swarm

## Decision

Use **Docker Compose** for local development and demo deployment.

## Rationale

1. **Single entry point.** `docker compose up -d` starts everything. No Kubernetes knowledge required to evaluate or onboard.

2. **Shared network by default.** All services communicate via Docker DNS (`http://nemo:8000`, `http://ollama:11434`). No external networking config required.

3. **Deterministic setup.** The `compose.yml` is the complete spec of what runs. No drift between environments.

4. **Right scope for this system.** This is an enterprise internal tool, not a public-facing service that needs horizontal scaling. A single well-provisioned node (8+ CPU cores, 16GB RAM for local inference) handles the load.

## Trade-offs Accepted

- **Not horizontally scalable.** A single Docker Compose deployment can't scale NeMo or LiteLLM horizontally. For high-throughput production, this needs Kubernetes + a Redis-backed LiteLLM cluster.
- **No rolling updates.** `docker compose restart` causes a brief outage. For zero-downtime, need a different deployment model.
- **No secret management.** `.env` files are good for development; production should use Vault, AWS Secrets Manager, or equivalent.

## Invalidation Signal

If the system needs to handle >100 concurrent requests or requires multi-region deployment, migrate to Kubernetes with Helm charts. LiteLLM has official Helm charts.
