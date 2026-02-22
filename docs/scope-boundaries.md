# Scope Boundaries

What this system is and is not responsible for.

---

## In Scope

- **API request interception** — every LLM request from configured tenants passes through this system
- **Secrets detection** — regex-based detection of API keys, credentials, connection strings in prompts
- **PII handling** — per-tenant strip/warn/block for emails, phone numbers, SSNs in prompts
- **Topic control** — semantic block-list and allow-list enforcement per tenant
- **Jailbreak detection** — structural manipulation attempt detection via LLM judge
- **Output safety** — checking LLM responses for policy violations before returning to client
- **Budget enforcement** — per-team dollar caps with automatic blocking at hard limits
- **Audit logging** — metadata-only event logs (no prompt/response content in production)
- **Tenant isolation** — virtual keys ensure team A cannot use team B's budget or see team B's config

---

## Out of Scope

### Authentication and Identity
This system trusts the virtual key presented by the client. It does not:
- Integrate with your identity provider (Okta, Azure AD) for SSO
- Enforce that a specific employee can only use their team's key
- Prevent key sharing between employees within a team

**Boundary:** Key management is the responsibility of the team administrator. The control plane enforces team-level policies, not individual-level policies.

### Data Retention and Logging of Content
The audit log records metadata (tenant, model, timestamp, token count, which rails fired) but not the content of prompts or responses. This is intentional.

- Storing prompt content creates GDPR/CCPA obligations
- Employees may not expect their queries to be retained
- Content retention is a separate system (SIEM, DLP platform)

**Boundary:** If you need to store and search prompt content for security investigations, integrate a dedicated SIEM.

### Compliance Certification
This system provides technical controls that *support* compliance programs, but it is not a compliance certification:

- Not SOC 2 certified (would require vendor audit)
- Not HIPAA compliant (healthcare data requires additional controls)
- Not PCI DSS compliant (payment data requires additional controls)

**Boundary:** Use this as one layer of a compliance program, not as the entire program.

### Response Quality and Accuracy
This system can detect and block harmful or off-topic responses, but it does not:
- Guarantee LLM accuracy or correctness
- Prevent hallucinations (fact-checking is probabilistic)
- Replace human review for high-stakes outputs

**Boundary:** Users remain responsible for verifying LLM outputs before acting on them.

### Network Security
This system runs on HTTP internally (Docker network). It does not:
- Provide TLS between services (the Docker network is trusted)
- Prevent access from other containers on the same Docker network
- Implement mTLS or service mesh security

**Boundary:** Deploy behind a TLS-terminating reverse proxy (nginx, Caddy, AWS ALB) in production. Add network policies if using Kubernetes.

### Multi-Tenancy at the Infrastructure Level
Teams share the same LiteLLM instance and NeMo instance. Isolation is logical (via virtual keys), not physical:

- One tenant's heavy load can impact another's latency
- A bug in the shared custom guardrail code affects all tenants
- NeMo's model is loaded once and shared

**Boundary:** For hard multi-tenancy (separate infrastructure per customer), this design needs to be extended with separate deployments per major tenant.

### Prompt and Response Caching
LiteLLM supports semantic caching (return cached responses for similar prompts). This feature is not enabled because:

- Caching across tenants could leak information (tenant A sees tenant B's response)
- Per-tenant caching requires careful key namespacing
- Cached responses bypass NeMo's output rails

**Boundary:** If you implement caching, do it per-tenant with namespaced cache keys and ensure NeMo's output rails still run on cache hits.
