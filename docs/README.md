# Dynamic CRM — Phase 1 engineering blueprint

This directory is the authoritative specification for the multi-tenant IT operations and CRM platform. Phase 1 is documentation. Application packages described in the architecture are the Phase 2 scaffold contract.

Read the documents in order. Later documents assume the requirement identifiers and decisions of the earlier ones.

| Document | Contents |
| --- | --- |
| [01_PRD.md](01_PRD.md) | Vision, personas, functional and non-functional requirements, acceptance criteria, capacity envelope |
| [02_ARCHITECTURE.md](02_ARCHITECTURE.md) | Monorepo, request and telemetry pipelines, tenancy, errors, realtime, security, build order |
| [03_DATABASE_SCHEMA.md](03_DATABASE_SCHEMA.md) | Executable PostgreSQL DDL, indexes, row-level security, TimescaleDB plan |
| [04_DYNAMIC_ENGINE.md](04_DYNAMIC_ENGINE.md) | Runtime Zod compilation, Angular dynamic forms, JSONB query patterns |
| [05_DESIGN_SYSTEM.md](05_DESIGN_SYSTEM.md) | The only color scheme, chart series, and application shell |

Executable migrations are in [sql/](sql/) and are copied into [03_DATABASE_SCHEMA.md](03_DATABASE_SCHEMA.md). `001_core.sql` is the relational schema. `002_timescale.sql` is the production metric store.

Normative words, used in every document:

- **MUST** — required for a Phase 2 implementation to conform
- **SHOULD** — required unless a recorded deviation explains the exception
- **MAY** — optional

When two documents disagree, the more specific statement wins. The product requirements win on behavior. The schema wins on column names and constraints. The dynamic-engine spec wins on validation and form behavior. The design system wins on color and layout.

Cursor and Antigravity load the same constraints on every task from `AGENTS.md`, `.cursorrules`, `.cursor/rules/`, and `.agents/rules/`. The source text is [agent-rules/](agent-rules/).
